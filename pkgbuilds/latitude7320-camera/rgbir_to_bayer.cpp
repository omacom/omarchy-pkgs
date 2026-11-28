/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * RGB-IR mosaic to Bayer conversion for libcamera's software ISP.
 */

#include "rgbir_to_bayer.h"

#include <algorithm>
#include <cmath>
#include <errno.h>
#include <string.h>

namespace libcamera {

RgbIrToBayer::RgbIrToBayer(const Channel pattern[16], uint16_t blackLevel,
			   unsigned int bitDepth)
	: blackLevel_(blackLevel),
	  maxValue_(static_cast<uint16_t>((1u << bitDepth) - 1))
{
	memset(counts_, 0, sizeof(counts_));
	memset(positions_, 0, sizeof(positions_));

	irSubTable_.resize((size_t)maxValue_ + 1, 0);

	for (uint8_t i = 0; i < 16; i++) {
		Channel c = pattern[i];
		/*
		 * Eight is the most any channel can occupy in a 4x4 cell that
		 * also contains three others; green hits exactly that.
		 */
		if (counts_[c] < 8)
			positions_[c][counts_[c]++] = i;
	}
}

namespace {

/*
 * Bilinear sample of a gain map. The map is far coarser than the image - 63x47
 * against 648x486 here - so nearest-neighbour would put visible steps in flat
 * areas, which is exactly where shading correction is most noticeable.
 */
inline uint32_t sampleGain(const uint16_t *map, unsigned int mw, unsigned int mh,
			   unsigned int x, unsigned int cols,
			   unsigned int y, unsigned int rows)
{
	if (cols < 2 || rows < 2)
		return map[0];

	unsigned int gx16 = x * (mw - 1) * 16 / (cols - 1);
	unsigned int gy16 = y * (mh - 1) * 16 / (rows - 1);
	unsigned int x0 = gx16 >> 4, y0 = gy16 >> 4;
	unsigned int fx = gx16 & 15, fy = gy16 & 15;
	unsigned int x1 = x0 + 1 < mw ? x0 + 1 : x0;
	unsigned int y1 = y0 + 1 < mh ? y0 + 1 : y0;

	uint32_t a = map[y0 * mw + x0], b = map[y0 * mw + x1];
	uint32_t c = map[y1 * mw + x0], d = map[y1 * mw + x1];
	uint32_t top = a * (16 - fx) + b * fx;
	uint32_t bot = c * (16 - fx) + d * fx;
	return (top * (16 - fy) + bot * fy) >> 8;
}

} /* namespace */

/*
 * Per-frame IR statistics, gathered on a 1-in-16 lattice of cells during the
 * conversion that is already reading them, and consumed by the next frame.
 *
 * Noise is estimated from the difference between the two IR samples sharing a
 * row of a cell. They sit two pixels apart, so they see very nearly the same
 * scene and differ only by noise except across an edge. The MEDIAN of those
 * differences is taken, not the mean: an edge or a texture inflates a mean
 * without bound, while moving a median takes more than half the sampled cells.
 * For X and Y independent and normal with the same sigma, median|X - Y| is
 * 0.954 * sigma, hence the reciprocal applied below.
 */
int32_t RgbIrToBayer::irRolloff(int32_t d, int32_t cellMax) const
{
	const int32_t full = (int32_t)maxValue_ - (int32_t)blackLevel_;
	/*
	 * 85% of full scale. Sensor response is already bending by then, so the
	 * IR-to-colour ratio the subtraction relies on is no longer the ratio
	 * that was calibrated. Below the knee nothing changes at all.
	 */
	const int32_t knee = full * 85 / 100;

	if (cellMax <= knee)
		return d;
	if (cellMax >= full || knee >= full)
		return 0;
	return (int32_t)((int64_t)d * (full - cellMax) / (full - knee));
}

void RgbIrToBayer::irStatsReset() const
{
	memset(irDiffHist_, 0, sizeof(irDiffHist_));
	irSum_ = 0;
	irSamples_ = 0;
	irDiffCount_ = 0;
}

void RgbIrToBayer::irStatsAccumulate(const int32_t cell[16], IrStats &stats) const
{
	const uint8_t n = counts_[Infrared];
	if (n < 2)
		return;

	/*
	 * Skip clipped cells outright. A saturated IR sample reports neither
	 * its level nor its noise - both are whatever the clamp left behind -
	 * and including them would drag the median toward zero and the mean
	 * toward full scale, pushing k up exactly where it should not be.
	 */
	const int32_t clip = (int32_t)maxValue_ - (int32_t)blackLevel_;
	for (uint8_t k = 0; k < n; k++)
		if (cell[positions_[Infrared][k]] >= clip)
			return;

	/*
	 * Signed, and negatives are kept. Once IR is down to a few counts a
	 * large share of samples fall below black, and dropping them turns the
	 * mean into E[max(X, 0)] - which for the measured dark-room case of 3
	 * counts under 5.2 reads 3.9 instead of 3.0 and holds k up at 0.72
	 * where the algebra calls for 0.50. Precisely the regime this exists
	 * for, so the bias has to go rather than be tolerated.
	 */
	for (uint8_t k = 0; k < n; k++)
		stats.sum += cell[positions_[Infrared][k]];
	stats.samples += n;

	/*
	 * Pair k with k+1. positions_ is filled in raster order, so an even k
	 * is the left IR sample of a cell row and k+1 its right neighbour.
	 */
	for (uint8_t k = 0; k + 1 < n; k += 2) {
		int32_t d = cell[positions_[Infrared][k]] -
			    cell[positions_[Infrared][k + 1]];
		if (d < 0)
			d = -d;
		stats.diffHist[d < (int32_t)kIrHistBins ? d : kIrHistBins - 1]++;
		stats.diffCount++;
	}
}

void RgbIrToBayer::irStatsMerge(const IrStats &stats) const
{
	irSum_ += stats.sum;
	irSamples_ += stats.samples;
	irDiffCount_ += stats.diffCount;
	for (unsigned int i = 0; i < kIrHistBins; i++)
		irDiffHist_[i] += stats.diffHist[i];
}

void RgbIrToBayer::irBuildTable() const
{
	if (irSubTable_.empty())
		return;

	/*
	 * Without a noise estimate - the first frame, or adaptive disabled -
	 * the table is just the tuned coefficient applied straight.
	 */
	const float s2 = irAdaptive_ ? irSigmaCell_ * irSigmaCell_ : 0.0f;
	for (size_t ir = 0; ir < irSubTable_.size(); ir++) {
		const float i = (float)ir;
		const float shrink = s2 > 0.0f ? (i * i) / (i * i + s2) : 1.0f;
		irSubTable_[ir] = (int32_t)(irSubtract_ * shrink * i);
	}
}

void RgbIrToBayer::irStatsFinish() const
{
	if (!irAdaptive_) {
		if (irEffective_ != irSubtract_ || irSigmaCell_ != 0.0f) {
			irEffective_ = irSubtract_;
			irSigmaCell_ = 0.0f;
			irBuildTable();
		}
		return;
	}

	/* No usable statistics: hold, rather than swing to an extreme. */
	if (!irSamples_ || !irDiffCount_)
		return;

	uint32_t run = 0, med = 0;
	const uint32_t target = irDiffCount_ / 2;
	for (unsigned int i = 0; i < kIrHistBins; i++) {
		run += irDiffHist_[i];
		if (run > target) {
			med = i;
			break;
		}
	}

	/*
	 * A median of zero means the IR plane is quantised flat - the scene is
	 * black, or every sampled cell clipped. The SNR is meaningless either
	 * way, so hold.
	 */
	if (!med)
		return;

	/*
	 * Per-pixel sigma from the median absolute difference, then the noise
	 * on a CELL average, which is what the shrinkage is applied to.
	 */
	const float sigma = 1.048f * (float)med;
	const uint8_t n = counts_[Infrared];
	const float sigmaCell = n > 1 ? sigma / std::sqrt((float)n) : sigma;

	/*
	 * Ramp rather than step. A cut in the room lights moves the curve a
	 * long way, and applied in one frame that reads as the colour popping;
	 * an eighth per frame settles in about a fifth of a second, well under
	 * the time the auto-exposure itself takes.
	 */
	if (irSigmaCell_ <= 0.0f)
		irSigmaCell_ = sigmaCell;
	else
		irSigmaCell_ += (sigmaCell - irSigmaCell_) / 8.0f;

	/* Summary for the log: the coefficient at the frame's mean IR level. */
	const float mean = (float)irSum_ / (float)irSamples_;
	const float I = mean > 0.0f ? mean : 0.0f;
	irEffective_ = irSubtract_ * (I * I) /
		       (I * I + irSigmaCell_ * irSigmaCell_);

	irBuildTable();
}

void RgbIrToBayer::cellValuesSharp(const uint8_t *lines[4], unsigned int cx,
				   unsigned int cols, unsigned int cy,
				   unsigned int rows, const ShadingMap *shading,
				   uint16_t G[4], uint16_t &R, uint16_t &B,
				   IrStats &stats) const
{
	int32_t cell[16];
	int32_t cellMax = 0;
	for (unsigned int dy = 0; dy < 4; dy++) {
		const uint8_t *p = lines[dy] + (cx * 4) * 2;
		for (unsigned int dx = 0; dx < 4; dx++) {
			int32_t v = p[0] | (p[1] << 8);
			v -= blackLevel_;
			cell[dy * 4 + dx] = v;
			if (v > cellMax)
				cellMax = v;
			p += 2;
		}
	}

	int32_t sum[4] = { 0, 0, 0, 0 };
	for (uint8_t c = 0; c < 4; c++)
		for (uint8_t k = 0; k < counts_[c]; k++)
			sum[c] += cell[positions_[c][k]];

	int32_t r = counts_[Red] ? sum[Red] / counts_[Red] : 0;
	int32_t b = counts_[Blue] ? sum[Blue] / counts_[Blue] : 0;

	/* One cell in sixteen feeds the adaptive coefficient. */
	if (irAdaptive_ && irSubtract_ > 0.0f && !(cx & 3) && !(cy & 3))
		irStatsAccumulate(cell, stats);

	/*
	 * Green per 2x2 quadrant. Derived from positions_ rather than assumed,
	 * so a differently-phased 4x4 pattern still works. A quadrant with no
	 * green falls back to the cell mean instead of emitting a hole.
	 */
	const int32_t gCell = counts_[Green] ? sum[Green] / counts_[Green] : 0;
	int32_t g[4];
	for (unsigned int q = 0; q < 4; q++) {
		const unsigned int qy = q >> 1, qx = q & 1;
		int32_t acc = 0;
		unsigned int n = 0;
		for (uint8_t k = 0; k < counts_[Green]; k++) {
			const uint8_t pos = positions_[Green][k];
			if ((pos >> 2) / 2 == qy && (pos & 3) / 2 == qx) {
				acc += cell[pos];
				n++;
			}
		}
		const int32_t gq = n ? acc / static_cast<int32_t>(n) : gCell;
		/*
		 * Blend toward the cell mean. The quadrant mean carries the
		 * detail and the cell mean carries the lower noise, so this
		 * slides between them rather than forcing a choice.
		 */
		g[q] = gCell + (int32_t)(sharpness_ * (float)(gq - gCell));
	}

	/*
	 * Optional infrared subtraction; see setIrSubtract(). Values are still
	 * black-level-relative at this point, which is what makes a plain
	 * subtraction the correct operation.
	 */
	if (irSubtract_ > 0.0f && counts_[Infrared]) {
		const int32_t ir = sum[Infrared] / counts_[Infrared];
		/*
		 * Faded out near saturation - the raw MAX of the cell, not the
		 * channel averages, because one clipped sample among eight is
		 * already enough to make the arithmetic wrong.
		 */
		const int32_t d = irRolloff(irSubtractFor(ir), cellMax);
		for (unsigned int q = 0; q < 4; q++)
			g[q] -= d;
		r -= d;
		b -= d;
	}

	if (shading) {
		const ShadingMap &s = *shading;
		const uint32_t one = s.one ? s.one : 1;
		if (s.gains[Green]) {
			const uint32_t gain = sampleGain(s.gains[Green], s.width, s.height, cx, cols, cy, rows);
			for (unsigned int q = 0; q < 4; q++)
				g[q] = (int32_t)((int64_t)g[q] * gain / one);
		}
		if (s.gains[Red])
			r = (int32_t)((int64_t)r * sampleGain(s.gains[Red], s.width, s.height, cx, cols, cy, rows) / one);
		if (s.gains[Blue])
			b = (int32_t)((int64_t)b * sampleGain(s.gains[Blue], s.width, s.height, cx, cols, cy, rows) / one);
	}

	const int32_t maxVal = maxValue_;
	auto clamp = [maxVal](int32_t v) -> uint16_t {
		if (v < 0)
			return 0;
		return v > maxVal ? (uint16_t)maxVal : (uint16_t)v;
	};

	for (unsigned int q = 0; q < 4; q++)
		G[q] = clamp(g[q] + blackLevel_);
	R = clamp(r + blackLevel_);
	B = clamp(b + blackLevel_);
}

void RgbIrToBayer::convertBand(const uint8_t *src, unsigned int srcStride,
			       uint16_t *dst, unsigned int dstPitch,
			       unsigned int cols, unsigned int rows,
			       unsigned int cyBegin, unsigned int cyEnd,
			       Order order, const ShadingMap *shading,
			       bool blurChroma, IrStats &stats) const
{
	for (unsigned int cy = cyBegin; cy < cyEnd; cy++) {
		const uint8_t *lines[4];
		for (unsigned int i = 0; i < 4; i++)
			lines[i] = src + (cy * 4 + i) * srcStride;

		uint16_t *out0 = dst + (cy * 2) * dstPitch;
		uint16_t *out1 = out0 + dstPitch;

		for (unsigned int cx = 0; cx < cols; cx++) {
			uint16_t G[4], R, B;
			cellValuesSharp(lines, cx, cols, cy, rows, shading, G, R, B,
					stats);

			/*
			 * The quad's green slots sit at its top-left and
			 * bottom-right, which is exactly where the cell's
			 * top-left and bottom-right quadrants are. The other
			 * two quadrant greens have no slot in a 2x2 Bayer quad
			 * and are necessarily dropped.
			 */
			out0[cx * 2 + 0] = G[0];
			out1[cx * 2 + 1] = G[3];

			if (blurChroma) {
				chromaR_[(size_t)cy * cols + cx] = R;
				chromaB_[(size_t)cy * cols + cx] = B;
			} else {
				const uint16_t t1 = order == Order::GRBG ? R : B;
				const uint16_t b0 = order == Order::GRBG ? B : R;
				out0[cx * 2 + 1] = t1;
				out1[cx * 2 + 0] = b0;
			}
		}
	}
}

void RgbIrToBayer::blurBand(uint16_t *dst, unsigned int dstPitch,
			    unsigned int cols, unsigned int cyBegin,
			    unsigned int cyEnd, unsigned int cyLow,
			    unsigned int cyHigh, Order order) const
{
	/*
	 * Green-guided average over a (2r+1)^2 cell neighbourhood, clamped to the
	 * converted band so it never reads rows this frame did not fill.
	 *
	 * cyLow/cyHigh are the whole converted band, not this thread's slice.
	 * Clamping to the slice instead would make every band edge behave like
	 * a frame edge and leave a seam across the picture at each one.
	 */
	const int r = (int)chromaBlur_;
	for (unsigned int cy = cyBegin; cy < cyEnd; cy++) {
		uint16_t *out0 = dst + (cy * 2) * dstPitch;
		uint16_t *out1 = out0 + dstPitch;
		const int y0 = std::max((int)cyLow, (int)cy - r);
		const int y1 = std::min((int)cyHigh - 1, (int)cy + r);

		for (unsigned int cx = 0; cx < cols; cx++) {
			const int x0 = std::max(0, (int)cx - r);
			const int x1 = std::min((int)cols - 1, (int)cx + r);
			/* Keep chroma smoothing on the same side of a luma edge.
			 * Blurring only R/B across a black-white boundary creates
			 * magenta in the black and green in the white. Green is
			 * unchanged by this pass, so it is a stable shared guide. */
			auto greenAt = [&](unsigned int x, unsigned int y) {
				return (int)(dst[(size_t)(2 * y) * dstPitch + 2 * x] +
					     dst[(size_t)(2 * y + 1) * dstPitch + 2 * x + 1]) / 2;
			};
			const int center = greenAt(cx, cy);
			const int threshold = 16 + std::max(0, center - (int)blackLevel_) / 8;
			uint32_t sr = 0, sb = 0;
			unsigned int n = 0;
			for (int y = y0; y <= y1; y++) {
				const size_t row = (size_t)y * cols;
				for (int x = x0; x <= x1; x++) {
					const int difference = std::abs(greenAt(x, y) - center);
					const unsigned int weight = std::max(0, threshold - difference);
					sr += weight * chromaR_[row + x];
					sb += weight * chromaB_[row + x];
					n += weight;
				}
			}
			const uint16_t R = (uint16_t)(sr / n);
			const uint16_t B = (uint16_t)(sb / n);
			const uint16_t t1 = order == Order::GRBG ? R : B;
			const uint16_t b0 = order == Order::GRBG ? B : R;
			out0[cx * 2 + 1] = t1;
			out1[cx * 2 + 0] = b0;
		}
	}
}

int RgbIrToBayer::convertSharp(const uint8_t *src, unsigned int srcWidth,
			       unsigned int srcHeight, unsigned int srcStride,
			       uint16_t *dst, unsigned int dstStride,
			       Order order, const ShadingMap *shading) const
{
	if (srcWidth % 4 || srcHeight % 4)
		return -EINVAL;

	const unsigned int cols = srcWidth / 4;
	const unsigned int rows = srcHeight / 4;
	const unsigned int dstPitch = dstStride / 2;

	irStatsReset();

	/*
	 * Each cell row produces output rows 2*cy and 2*cy+1, so converting
	 * output rows [activeY0_, activeY1_) means cell rows [y0/2, (y1-1)/2].
	 * Shading and the IR average are per-cell and do not depend on
	 * neighbouring cells, so skipping rows changes nothing in the rows that
	 * are kept.
	 */
	unsigned int cy0 = 0, cy1 = rows;
	if (activeY1_ > activeY0_) {
		cy0 = activeY0_ / 2;
		cy1 = std::min(rows, (activeY1_ + 1) / 2 + 1);
	}

	/*
	 * Green is written as it is computed; red and blue are buffered so they
	 * can be smoothed across neighbouring cells first. Chroma carries most
	 * of the visible noise here - on a flat patch, luma sd 5.64 against Cr
	 * 10.03 - because red occupies 2 of 16 mosaic positions and the colour
	 * matrix then amplifies that row 1.90x. Blurring it costs almost nothing
	 * real, since one red value already covers a 4x4 block of sensor pixels.
	 */
	const bool blurChroma = chromaBlur_ > 0;
	if (blurChroma) {
		chromaR_.assign((size_t)cols * rows, 0);
		chromaB_.assign((size_t)cols * rows, 0);
	}

	/*
	 * One band per thread, split by cell row. Equal sized rather than work
	 * stealing: every cell costs the same here, so the bands finish
	 * together and a scheduler would only add synchronisation.
	 */
	const unsigned int active = cy1 > cy0 ? cy1 - cy0 : 0;
	unsigned int bands = pool_ ? pool_->size() : 1;
	if (bands > active)
		bands = active ? active : 1;

	std::vector<IrStats> stats(bands);
	auto bandRange = [&](unsigned int b, unsigned int &begin, unsigned int &end) {
		begin = cy0 + active * b / bands;
		end = cy0 + active * (b + 1) / bands;
	};

	auto pass1 = [&](unsigned int b) {
		unsigned int begin, end;
		bandRange(b, begin, end);
		convertBand(src, srcStride, dst, dstPitch, cols, rows,
			    begin, end, order, shading, blurChroma, stats[b]);
	};

	if (pool_ && bands > 1)
		pool_->run(bands, pass1);
	else
		pass1(0);

	for (const IrStats &st : stats)
		irStatsMerge(st);

	if (blurChroma) {
		/*
		 * Separate pass, and therefore after a barrier: the box average
		 * reads cell rows this thread did not write.
		 */
		auto pass2 = [&](unsigned int b) {
			unsigned int begin, end;
			bandRange(b, begin, end);
			blurBand(dst, dstPitch, cols, begin, end, cy0, cy1, order);
		};

		if (pool_ && bands > 1)
			pool_->run(bands, pass2);
		else
			pass2(0);
	}

	irStatsFinish();

	return 0;
}

} /* namespace libcamera */
