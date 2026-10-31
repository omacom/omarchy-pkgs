/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * RGB-IR mosaic to Bayer conversion for libcamera's software ISP.
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

#include <memory>
#include <vector>

#include "thread_pool.h"

namespace libcamera {

/**
 * \brief Convert a 4x4 RGB-IR mosaic to a half-resolution Bayer image
 *
 * Some sensors - the OV5678 on the Dell Latitude 7320 Detachable among them -
 * use a 4x4 colour filter array with one infrared pixel in four:
 *
 *     G I G I
 *     R G B G
 *     G I G I
 *     B G R G
 *
 * The software ISP handles 2x2 mosaics only. Read as a 2x2 Bayer, the IR
 * pixels are mistaken for one colour channel and the red and blue pixels are
 * averaged into another, which destroys colour rather than merely degrading
 * it.
 *
 * Rather than teach the whole ISP a new mosaic, this converts to Bayer up
 * front, as Intel's own IPU6 hardware does in its "x2b_rgbir" block, after
 * which the existing debayer, statistics, AWB and CCM all work unmodified.
 *
 * The output is half the input dimensions, and that ratio is not a
 * compromise: a 4x4 RGB-IR cell holds exactly two red and two blue pixels,
 * and a 2x2 Bayer cell at half resolution needs exactly one of each. Chroma
 * maps across with nothing discarded - RGB-IR chroma density at half
 * resolution *is* Bayer density. Green averages four into one, the same
 * reduction the sensor's own binned mode performs, except that binning
 * averages IR in with colour and this does not.
 *
 * The IR pixels are dropped. Subtracting IR from the colour channels needs a
 * per-illuminant model and is left to a later change; on this hardware under
 * LED lighting the measured IR/G ratio is about 0.10, so the correction is
 * second order. Under tungsten it would not be.
 */
class RgbIrToBayer
{
public:
	/**
	 * \brief Bayer order of the generated output
	 *
	 * Must match what the consumer was configured for. Getting this wrong
	 * transposes red and blue, which is the exact fault this conversion
	 * exists to remove, so it is explicit rather than defaulted.
	 */
	enum class Order {
		GRBG,   /* G R / B G */
		GBRG,   /* G B / R G */
	};

	/** \brief Which channel sits at each position of the 4x4 cell */
	enum Channel : uint8_t {
		Green = 0,
		Infrared = 1,
		Red = 2,
		Blue = 3,
	};

	/**
	 * \brief Per-channel spatial gain map, e.g. lens shading
	 *
	 * Gains are applied before the mosaic is collapsed, which is the only
	 * point at which each pixel's channel is still known. Indexed by
	 * Channel. A null \a gains disables correction.
	 *
	 * Values are fixed point with \a one representing unity, matching the
	 * convention of the tuning data they typically come from.
	 */
	struct ShadingMap {
		const uint16_t *gains[4];
		unsigned int width;
		unsigned int height;
		uint16_t one;
	};

	/**
	 * \param[in] pattern Channel at each of the 16 cell positions, row major
	 * \param[in] blackLevel Sensor pedestal, subtracted before any gain
	 * \param[in] bitDepth Significant bits of the raw format, e.g. 10
	 *
	 * \a bitDepth is not cosmetic. The CPU debayer indexes 256-entry lookup
	 * tables with the raw value shifted down to 8 bits, so a value above the
	 * format's full scale indexes out of bounds. Shading gains reach 3.5x on
	 * this hardware, which is comfortably enough to get there, so the output
	 * is clamped to full scale rather than to the container.
	 */
	RgbIrToBayer(const Channel pattern[16], uint16_t blackLevel,
		     unsigned int bitDepth = 10);

	/**
	 * \brief Convert one frame to half-resolution Bayer
	 * \param[in] src 16-bit input, \a srcStride bytes per line
	 * \param[in] srcWidth Input width, must be a multiple of 4
	 * \param[in] srcHeight Input height, must be a multiple of 4
	 * \param[out] dst 16-bit output, half the input dimensions
	 * \param[in] order Bayer order to emit
	 * \param[in] shading Optional per-channel gain maps
	 *
	 * The output mosaic is GRBG by default: green at (0,0), red at (0,1),
	 * blue at (1,0), green at (1,1).
	 *
	 * Chroma is one value per 4x4 cell. Red and blue are only 2 of the 16
	 * positions each and a 2x2 output quad has exactly one slot for each,
	 * so they map straight across with nothing discarded and there is
	 * nothing to gain by doing more.
	 *
	 * Green is the choice. The cell holds eight of them and the quad has
	 * two slots, so averaging all eight into ONE value and writing it to
	 * both would leave luma flat across the cell - the output effectively
	 * 4x4 binned when the geometry only calls for 2x. The mosaic makes
	 * better available for free: split the cell into four 2x2 quadrants and
	 * each holds exactly two greens, so the quad's two green slots can
	 * carry the top-left and bottom-right quadrant means instead of one
	 * number twice. Green then sits at the same density it does in Bayer,
	 * so that is real detail, not interpolation. setSharpness() slides
	 * between the two, and it is a noise trade rather than a free win - see
	 * there before reaching for it. Luma is what the eye reads for
	 * sharpness anyway, which is why green gets this treatment and chroma
	 * does not.
	 *
	 * \return 0 on success, -EINVAL if the dimensions are not multiples of 4
	 */
	int convertSharp(const uint8_t *src, unsigned int srcWidth,
			 unsigned int srcHeight, unsigned int srcStride,
			 uint16_t *dst, unsigned int dstStride,
			 Order order = Order::GRBG,
			 const ShadingMap *shading = nullptr) const;

private:
	/*
	 * Per-band IR statistics.
	 *
	 * Every field is a plain sum, so bands merge by adding. They have to be
	 * per band rather than per object: convertSharp() runs its cell loop on
	 * several threads, and accumulating straight into the members would be
	 * a data race on every cell.
	 */
	struct IrStats {
		int64_t sum = 0;
		uint32_t samples = 0;
		uint32_t diffCount = 0;
		uint32_t diffHist[256] = {};
	};

	/*
	 * Shared per-cell work: gather, average, shade, re-add the pedestal.
	 * Green is returned per 2x2 quadrant of the cell, in raster order
	 * (top-left, top-right, bottom-left, bottom-right).
	 */
	void cellValuesSharp(const uint8_t *lines[4], unsigned int cx,
			     unsigned int cols, unsigned int cy,
			     unsigned int rows, const ShadingMap *shading,
			     uint16_t G[4], uint16_t &R, uint16_t &B,
			     IrStats &stats) const;

	/* Positions within the cell holding each channel, and how many. */
	uint8_t positions_[4][8];
	uint8_t counts_[4];
	float sharpness_ = 1.0f;
	unsigned int chromaBlur_ = 0;
	mutable std::vector<uint16_t> chromaR_;
	mutable std::vector<uint16_t> chromaB_;
	unsigned int activeY0_ = 0;
	unsigned int activeY1_ = 0;
	uint16_t blackLevel_;
	uint16_t maxValue_;
	float irSubtract_ = 0.0f;

	/*
	 * Adaptive IR subtraction state. Statistics are gathered during the
	 * conversion, which already has every cell in registers, and applied to
	 * the next frame; exposure moves far slower than 33 ms, and this avoids
	 * a second pass over five megapixels.
	 */
	static constexpr unsigned int kIrHistBins = 256;
	bool irAdaptive_ = false;
	mutable float irEffective_ = 0.0f;
	mutable float irSigmaCell_ = 0.0f;
	mutable int64_t irSum_ = 0;
	mutable uint32_t irSamples_ = 0;
	mutable uint32_t irDiffHist_[kIrHistBins] = {};
	mutable uint32_t irDiffCount_ = 0;
	/*
	 * How much to subtract for each possible cell IR level, rebuilt once a
	 * frame. A table because the shrinkage is a divide, and a divide in the
	 * per-cell path is 300k of them a frame for a curve that only changes
	 * when the light does.
	 */
	mutable std::vector<int32_t> irSubTable_;

	/*
	 * Created on first use and reused, so the threads are made once rather
	 * than 30 times a second. Mutable because convertSharp() is const: it
	 * does not change what the object represents, only how the work is
	 * divided.
	 */
	unsigned int threads_ = 1;
	mutable std::unique_ptr<ThreadPool> pool_;

	/*
	 * Scale an IR subtraction down as a cell approaches saturation.
	 *
	 * The model colour_true = colour_measured - k*IR holds only while
	 * nothing is clipped. In a blown highlight - a ceiling light, a
	 * reflection off anything shiny - every channel including IR pins at
	 * full scale, so the subtraction removes k times the whole signal and
	 * the result clamps at zero. The brightest thing in the frame comes out
	 * BLACK: measured on this hardware, 14.1% of the pixels around a
	 * ceiling light, against 0% with the subtraction disabled.
	 *
	 * Above the knee the measurement can no longer be trusted, so the
	 * correction is faded out rather than switched off, which would put a
	 * visible edge around every highlight. At full scale nothing is
	 * subtracted and clipped white stays white, which is what a blown
	 * highlight should look like.
	 */
	int32_t irRolloff(int32_t d, int32_t cellMax) const;

	void irStatsReset() const;
	void irStatsAccumulate(const int32_t cell[16], IrStats &stats) const;
	void irStatsMerge(const IrStats &stats) const;
	void irStatsFinish() const;

	/* One band of the cell loop, and one band of the chroma blur. */
	void convertBand(const uint8_t *src, unsigned int srcStride,
			 uint16_t *dst, unsigned int dstPitch,
			 unsigned int cols, unsigned int rows,
			 unsigned int cyBegin, unsigned int cyEnd,
			 Order order, const ShadingMap *shading,
			 bool blurChroma, IrStats &stats) const;
	void blurBand(uint16_t *dst, unsigned int dstPitch, unsigned int cols,
		      unsigned int cyBegin, unsigned int cyEnd,
		      unsigned int cyLow, unsigned int cyHigh, Order order) const;
	void irBuildTable() const;

	/* Amount to subtract from R, G and B for a cell whose IR average is \a ir */
	int32_t irSubtractFor(int32_t ir) const
	{
		if (ir <= 0 || irSubTable_.empty())
			return 0;
		return irSubTable_[ir < (int32_t)irSubTable_.size()
					   ? ir : irSubTable_.size() - 1];
	}

public:
	/**
	 * \brief Set how much of the infrared plane to subtract from R, G and B
	 * \param[in] k Coefficient, 0 disables
	 *
	 * Every colour photosite on this sensor also responds to near-infrared,
	 * so the colour channels carry an IR pedestal that desaturates them.
	 * Subtracting k times the cell's IR average removes it.
	 *
	 * The trade is noise. IR is by far the weakest channel here - of order
	 * 9 counts against green's 98 - so subtracting it adds its noise to all
	 * three colour channels, and the penalty scales with k. Judged by eye
	 * on this hardware, k=1.0 is visibly cleaner than k=2.0 while k=2.0 is
	 * the more colour-accurate; saturation applied afterwards buys chroma
	 * without that noise cost, so prefer a low k with more saturation.
	 */
	/**
	 * \brief Split each frame across \a n threads, including the caller's
	 * \param[in] n Total threads, 0 or 1 for the single-threaded path
	 *
	 * The work divides into horizontal bands of cell rows. Bands are
	 * independent in the first pass - a cell reads only its own 4x4 source
	 * block - and the chroma blur that follows is separated from it by a
	 * barrier, so it can read across band boundaries safely. Neither pass
	 * writes outside its own band.
	 *
	 * Beyond the physical core count this stops helping: the pass is
	 * limited by memory bandwidth as much as arithmetic, and two SMT
	 * siblings share one set of load/store units. Measure before assuming
	 * hardware_concurrency() is the right number.
	 */
	void setThreads(unsigned int n)
	{
		const unsigned int want = n < 1 ? 1 : n;
		if (want == threads_ && (pool_ || want == 1))
			return;
		threads_ = want;
		pool_ = want > 1 ? std::make_unique<ThreadPool>(want) : nullptr;
	}

	void setIrSubtract(float k)
	{
		irSubtract_ = k;
		irEffective_ = k;
		irBuildTable();
	}

	/**
	 * \brief Scale the IR coefficient by how much of IR is real signal
	 *
	 * A fixed coefficient is only right while the IR plane is well exposed.
	 * IR is by far the weakest channel here, so it is the first to run out
	 * of photons. Measured on this sensor in one frame: a well-lit patch
	 * carries 61 counts of IR under 13.6 of noise, an SNR of 4.5, while a
	 * dim patch of the same frame carries 3 counts under 5.2, an SNR of
	 * 0.6. Subtracting 2x of the latter from R, G and B is subtracting
	 * noise, not infrared - on a dark-room frame k=2.0 produced 1.7x the
	 * grain of k=0.5, for saturation that was barely present to begin with.
	 *
	 * Rather than add another knob to get wrong, pick k to minimise the
	 * total error. Writing I for the true IR, s for the noise on the
	 * estimate of it, and a for the coefficient set by setIrSubtract(),
	 * subtracting k*(I + n) leaves a residual colour cast of (a - k)*I and
	 * injects noise of k*s. The sum of squares
	 *
	 *     (a - k)^2 * I^2 + k^2 * s^2
	 *
	 * is minimised at
	 *
	 *     k = a * I^2 / (I^2 + s^2) = a * SNR^2 / (1 + SNR^2)
	 *
	 * which is Wiener shrinkage, and carries no tuning constant of its own:
	 * it returns the full tuned coefficient where IR is clean and falls
	 * away as IR becomes noise. On the two measurements above, with s the
	 * noise on the cell average rather than on one pixel, it gives 1.98 in
	 * the lit patch and 1.14 in the dim one.
	 *
	 * Crucially k is applied PER CELL, using that cell's own IR average as
	 * I. A single frame-wide coefficient is the wrong object: a frame that
	 * contains a lamp and a dim wall has a mean IR dominated by the lamp, so
	 * global MSE says keep subtracting - measured on this hardware, a whole
	 * dark room held k at 1.99 - while the wall, where the grain actually
	 * is, sits at 3 counts of IR under 5 of noise. Shrinking per cell asks
	 * the question where it matters and needs no frame mean at all.
	 *
	 * Only the noise estimate is frame-wide, which is what it should be:
	 * read noise does not vary across the sensor, and estimating it from
	 * the whole frame is what makes it robust. It is measured on the
	 * previous frame, since exposure moves far slower than 33 ms.
	 *
	 * Note the cell IR average is the mean of counts_[Infrared] samples, so
	 * its noise is sigma/sqrt(n) - four IR pixels per cell here, so half.
	 * Using the per-pixel sigma instead would shrink twice as hard as the
	 * algebra calls for.
	 */
	void setIrAdaptive(bool on) { irAdaptive_ = on; }

	/**
	 * \brief Representative coefficient for the last frame
	 *
	 * The coefficient now varies per cell, so this reports the value at the
	 * frame's mean IR level - a summary for logging, not the thing applied.
	 */
	float effectiveIrSubtract() const { return irEffective_; }

	/** \brief Effective coefficient for a cell whose IR average is \a ir */
	float irCoefficientAt(int32_t ir) const
	{
		return ir > 0 ? (float)irSubtractFor(ir) / (float)ir : 0.0f;
	}

	/**
	 * \brief Smooth red and blue across neighbouring cells
	 * \param[in] radius 0 disables, 1 is a 3x3 cell average, 2 is 5x5
	 *
	 * Chroma is where the noise actually is. Measured on a flat patch of the
	 * finished pipeline: luma sd 5.64, Cb 5.56, but **Cr 10.03** - red-
	 * difference noise is nearly double the luma. Red sits at only 2 of the
	 * 16 mosaic positions, an eighth the density of green, and the colour
	 * matrix then amplifies that row 1.90x.
	 *
	 * Smoothing it is unusually cheap here because red and blue are ALREADY
	 * per-cell - one value per 4x4 block of sensor pixels. Averaging across
	 * neighbouring cells blurs something that was never sharp, while green,
	 * which carries the detail the eye reads as sharpness, is untouched.
	 */
	void setChromaBlur(unsigned int radius) { chromaBlur_ = radius; }

	/**
	 * \brief Restrict conversion to a band of output rows
	 * \param[in] y0 First output row to produce
	 * \param[in] y1 One past the last output row to produce
	 *
	 * The consumer of this conversion crops. On this machine the pre-pass
	 * emits 1296x972 and the debayer then reads a 1280x720 window at
	 * (8,126), so 252 of the 972 rows - 26% - are computed and thrown away.
	 * Converting only the band that is actually read removes that work from
	 * every frame, and the pipeline is CPU bound on one core.
	 *
	 * Rows outside the band are left untouched, so the caller must not read
	 * them. Pass y1 <= y0 to disable and convert everything.
	 */
	void setActiveRows(unsigned int y0, unsigned int y1)
	{
		activeY0_ = y0;
		activeY1_ = y1;
	}

	/**
	 * \brief How much intra-cell green detail convertSharp() restores
	 * \param[in] k 0 for the cell mean, 1 for the quadrant mean, clamped
	 *
	 * 0 makes every output green the mean of all eight in the cell, written
	 * to both green slots of the quad, which is the quietest option and
	 * leaves luma flat across the cell. 1 gives each green slot its own 2x2
	 * quadrant mean, which is the sharpest. Values between blend the two.
	 *
	 * This is a resolution-for-noise trade and NOT a free win. Measured on
	 * a real frame: 1 gives 1.49x the vertical detail but 1.43x the noise,
	 * leaving detail-to-noise essentially unchanged at 1.04x. Averaging two
	 * samples instead of eight can only divide read noise by sqrt(2) rather
	 * than sqrt(8). On a low-detail scene the extra grain is what you see;
	 * on a detailed one, the detail is. Hence a knob rather than a default.
	 */
	void setSharpness(float k) { sharpness_ = k < 0.0f ? 0.0f : (k > 1.0f ? 1.0f : k); }
};

} /* namespace libcamera */
