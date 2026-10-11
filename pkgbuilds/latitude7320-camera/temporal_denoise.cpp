/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * Motion-adaptive temporal denoise for the software ISP.
 */

#include "temporal_denoise.h"

#include <algorithm>
#include <string.h>

namespace libcamera {

void TemporalDenoise::configure(float alpha, uint16_t threshold)
{
	if (alpha < 0.01f)
		alpha = 0.01f;
	else if (alpha > 1.0f)
		alpha = 1.0f;
	alpha_ = alpha;
	threshold_ = threshold ? threshold : 1;
}

void TemporalDenoise::setGainMap(const uint16_t *map, unsigned int mapW,
				 unsigned int mapH, uint16_t one,
				 unsigned int frameW, unsigned int frameH,
				 unsigned int rowOffset)
{
	if (map == gainMap_ && mapW == gainMapW_ && mapH == gainMapH_ &&
	    one == gainOne_ && frameW == frameW_ && frameH == frameH_ &&
	    rowOffset == rowOffset_)
		return;

	gainMap_ = map;
	gainMapW_ = mapW;
	gainMapH_ = mapH;
	gainOne_ = one;
	frameW_ = frameW;
	frameH_ = frameH;
	rowOffset_ = rowOffset;
	gainDirty_ = true;
}

namespace {

/* Bilinear sample of a coarse map at normalised (u, v), both in [0, 1]. */
uint32_t sampleMap(const uint16_t *map, unsigned int mw, unsigned int mh,
		   float u, float v)
{
	if (mw < 2 || mh < 2)
		return map[0];

	const float fx = u * (mw - 1), fy = v * (mh - 1);
	unsigned int x0 = (unsigned int)fx, y0 = (unsigned int)fy;
	if (x0 > mw - 2)
		x0 = mw - 2;
	if (y0 > mh - 2)
		y0 = mh - 2;
	const float dx = fx - x0, dy = fy - y0;

	const float a = map[y0 * mw + x0], b = map[y0 * mw + x0 + 1];
	const float c = map[(y0 + 1) * mw + x0], d = map[(y0 + 1) * mw + x0 + 1];
	const float top = a + (b - a) * dx, bot = c + (d - c) * dx;
	return (uint32_t)(top + (bot - top) * dy + 0.5f);
}

} /* namespace */

void TemporalDenoise::buildTileScale(unsigned int tx, unsigned int ty)
{
	tileScale_.assign((size_t)tx * ty, 256);
	if (!gainMap_ || !gainOne_ || !frameW_ || !frameH_)
		return;

	for (unsigned int by = 0; by < ty; by++) {
		for (unsigned int bx = 0; bx < tx; bx++) {
			/*
			 * Tile centre, in absolute frame coordinates - the
			 * caller may hand us only the band it converted.
			 */
			const float cx = bx * kTile + kTile / 2.0f;
			const float cy = by * kTile + kTile / 2.0f + rowOffset_;
			const float u = std::min(1.0f, cx / (float)(frameW_ - 1));
			const float v = std::min(1.0f, cy / (float)(frameH_ - 1));
			const uint32_t g = sampleMap(gainMap_, gainMapW_, gainMapH_, u, v);
			uint32_t s = g * 256u / gainOne_;
			if (s < 1)
				s = 1;
			else if (s > 65535)
				s = 65535;
			tileScale_[(size_t)by * tx + bx] = (uint16_t)s;
		}
	}
}

void TemporalDenoise::apply(uint16_t *frame, size_t count)
{
	if (alpha_ >= 1.0f) {
		motionFraction_ = 1.0f;
		return;
	}

	/*
	 * First frame, or a geometry change: seed the history and emit the
	 * frame untouched. Blending against a stale buffer of a different size
	 * would be worse than not denoising at all.
	 */
	if (history_.size() != count) {
		history_.assign(frame, frame + count);
		motionFraction_ = 1.0f;
		return;
	}

	/*
	 * Motion is decided over runs of kBlock samples rather than per sample,
	 * and each run's mean |cur - prev| has the frame's own noise floor
	 * subtracted from it first. The runs are linear, not square: at this
	 * width one run is about a fifth of a Bayer row, which is compact
	 * enough to localise motion and avoids the addressing a 2D tile needs.
	 *
	 * Both parts are needed. Per-sample differences ARE the noise in a
	 * still scene, so using them directly drives the blend weight up and
	 * throttles the very averaging this exists to do - measured 1.44x
	 * instead of the 2.6x the recursion should give at alpha 0.25.
	 * Averaging |d| over a block does not help on its own either, because
	 * E[|d|] stays at the noise level however many samples go into it; only
	 * the *variance* of the estimate falls. Subtracting the floor is what
	 * actually separates "this moved" from "this is a sensor".
	 *
	 * The floor is estimated from the frame itself, as the 10th percentile
	 * of the block means, so it tracks exposure and analogue gain with no
	 * tuning. In a still scene almost every block is noise, so a low
	 * percentile is the noise level by construction.
	 */
	/*
	 * Motion is decided over square TILES when the geometry is known.
	 *
	 * It used to be runs of consecutive samples, which at this width is a
	 * horizontal strip a fifth of a row wide. A moving edge updated some
	 * strips and not others and left horizontal seams across it, which reads
	 * as interlacing combing - the most obvious artefact the filter produced.
	 *
	 * Each tile's mean |cur - prev| has the frame's own noise floor
	 * subtracted before it counts as motion. Both parts are needed:
	 * per-sample differences ARE the noise in a still scene, so using them
	 * directly throttles the averaging (measured 1.44x instead of 2.6x); and
	 * averaging |d| alone does not help, because E[|d|] stays at the noise
	 * level however many samples go into it. Only subtracting the floor
	 * separates "this moved" from "this is a sensor".
	 */
	const bool tiled = width_ > 0 && height_ > 0 &&
			   (size_t)width_ * height_ <= count;
	const unsigned int tx = tiled ? (width_ + kTile - 1) / kTile : 0;
	const unsigned int ty = tiled ? (height_ + kTile - 1) / kTile : 0;
	const unsigned int blocks = tiled ? tx * ty
					  : (unsigned int)((count + kBlock - 1) / kBlock);
	blockMotion_.resize(blocks);

	auto tileBounds = [&](unsigned int b, unsigned int &x0, unsigned int &x1,
			      unsigned int &y0, unsigned int &y1) {
		const unsigned int bx = b % tx, by = b / tx;
		x0 = bx * kTile; x1 = std::min(x0 + kTile, width_);
		y0 = by * kTile; y1 = std::min(y0 + kTile, height_);
	};

	for (unsigned int b = 0; b < blocks; b++) {
		uint32_t acc = 0;
		unsigned int n = 0;
		if (tiled) {
			unsigned int x0, x1, y0, y1;
			tileBounds(b, x0, x1, y0, y1);
			for (unsigned int y = y0; y < y1; y += 2) {
				const size_t row = (size_t)y * width_;
				for (unsigned int x = x0; x < x1; x += 2) {
					int32_t d = (int32_t)frame[row + x] -
						    (int32_t)history_[row + x];
					acc += d < 0 ? -d : d;
					n++;
				}
			}
		} else {
			const size_t s0 = (size_t)b * kBlock;
			const size_t s1 = std::min(s0 + kBlock, count);
			for (size_t i = s0; i < s1; i += 4) {
				int32_t d = (int32_t)frame[i] - (int32_t)history_[i];
				acc += d < 0 ? -d : d;
				n++;
			}
		}
		blockMotion_[b] = (uint16_t)(n ? acc / n : 0);
	}

	/*
	 * Divide out the gain applied to each tile, so a tile's motion means
	 * the same thing wherever it sits. Without this the shading-amplified
	 * corners read as permanent motion and are never averaged at all.
	 */
	if (tiled && gainMap_) {
		if (gainDirty_ || tileScale_.size() != blocks) {
			buildTileScale(tx, ty);
			gainDirty_ = false;
		}
		for (unsigned int b = 0; b < blocks; b++) {
			const uint32_t s = tileScale_[b];
			blockMotion_[b] = (uint16_t)((uint32_t)blockMotion_[b] * 256u / s);
		}
	}

	/* nth_element, not sort: only the 10th percentile is wanted. */
	scratch_.assign(blockMotion_.begin(), blockMotion_.end());
	const size_t k = scratch_.size() / 10;
	std::nth_element(scratch_.begin(), scratch_.begin() + k, scratch_.end());
	const int32_t floor = scratch_[k];

	const int32_t aFix = static_cast<int32_t>(alpha_ * 256.0f + 0.5f);
	const int32_t thr = threshold_;
	size_t moving = 0;

	auto weightOf = [&](unsigned int b) -> int32_t {
		int32_t m = (int32_t)blockMotion_[b] - floor;
		if (m < 0)
			m = 0;
		return m >= thr ? 256 : aFix + (256 - aFix) * m / thr;
	};

	if (tiled) {
		/*
		 * Interpolate the weight between tile centres rather than
		 * stepping it at tile edges.
		 *
		 * One weight per 32x32 tile makes the tile itself visible: when
		 * something moves, neighbouring tiles average by different
		 * amounts and the seams between them read as SQUARES drifting
		 * over the picture. It is the same failure as the horizontal
		 * combing that square tiles replaced - the artefact follows
		 * whatever shape the motion decision is quantised to, so the fix
		 * is to stop it being quantised at all on the output side.
		 *
		 * The decision stays per tile, which is what makes it robust
		 * against noise; only its APPLICATION is smoothed. A pixel takes
		 * a bilinear blend of the four tile weights around it, so the
		 * weight field is continuous and no edge exists to see.
		 */
		weights_.resize(blocks);
		for (unsigned int b = 0; b < blocks; b++) {
			weights_[b] = weightOf(b);
			if (weights_[b] > 200)
				moving++;
		}

		/*
		 * Walked in spans rather than per pixel. The obvious form - work
		 * out which tiles a pixel sits between, and interpolate - costs
		 * two signed divisions and two clamps per pixel, and measured
		 * 79.7 ms a frame against 26: 12 fps. Between two tile centres
		 * the pair of tiles is fixed and the blend advances by a
		 * constant, so the whole thing reduces to one add per pixel.
		 */
		weights_.resize(blocks);
		for (unsigned int b = 0; b < blocks; b++) {
			weights_[b] = weightOf(b);
			if (weights_[b] > 200)
				moving++;
		}

		const int32_t half = kTile / 2;
		vcol_.resize(tx);

		for (unsigned int y = 0; y < height_; y++) {
			const int32_t gy = (int32_t)y - half;
			const int32_t by0 = gy < 0 ? 0 : std::min((int32_t)ty - 1, gy / (int32_t)kTile);
			const int32_t by1 = std::min((int32_t)ty - 1, by0 + 1);
			const int32_t fy = gy < 0 ? 0 : gy - by0 * (int32_t)kTile;
			const int32_t *rowA = &weights_[(size_t)by0 * tx];
			const int32_t *rowB = &weights_[(size_t)by1 * tx];

			/* Vertical blend once per tile column: w * kTile. */
			for (unsigned int bx = 0; bx < tx; bx++)
				vcol_[bx] = rowA[bx] * (kTile - fy) + rowB[bx] * fy;

			uint16_t *f = frame + (size_t)y * width_;
			uint16_t *h = history_.data() + (size_t)y * width_;

			auto run = [&](unsigned int x0, unsigned int x1, int32_t acc,
				       int32_t step) {
				for (unsigned int x = x0; x < x1; x++, acc += step) {
					/* acc is w * kTile * kTile; kTile^2 = 1024. */
					const int32_t w = acc >> 10;
					const int32_t cur = f[x], prev = h[x];
					const int32_t out = prev + ((cur - prev) * w >> 8);
					const uint16_t v = (uint16_t)(out < 0 ? 0 : out);
					f[x] = v;
					h[x] = v;
				}
			};

			/* Before the first tile centre the weight is simply tile 0's. */
			const unsigned int lead = std::min((unsigned int)half, width_);
			run(0, lead, vcol_[0] * kTile, 0);

			for (unsigned int bx = 0; bx + 1 < tx; bx++) {
				const unsigned int x0 = half + bx * kTile;
				if (x0 >= width_)
					break;
				const unsigned int x1 = std::min(x0 + kTile, width_);
				run(x0, x1, vcol_[bx] * kTile, vcol_[bx + 1] - vcol_[bx]);
			}

			/* And after the last centre, the last tile's. */
			const unsigned int tail = std::min(width_, half + (tx - 1) * kTile);
			run(tail, width_, vcol_[tx - 1] * kTile, 0);
		}
	} else {
		for (unsigned int b = 0; b < blocks; b++) {
			const int32_t w = weightOf(b);
			if (w > 200)
				moving++;
			const size_t s0 = (size_t)b * kBlock;
			const size_t s1 = std::min(s0 + kBlock, count);
			for (size_t i = s0; i < s1; i++) {
				const int32_t cur = frame[i], prev = history_[i];
				const int32_t out = prev + ((cur - prev) * w >> 8);
				const uint16_t v = (uint16_t)(out < 0 ? 0 : out);
				frame[i] = v;
				history_[i] = v;
			}
		}
	}

	motionFraction_ = blocks ? static_cast<float>(moving) / blocks : 0.0f;
}

} /* namespace libcamera */
