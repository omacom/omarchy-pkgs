/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Copyright (C) 2026, Sahan Nissanka
 *
 * Motion-adaptive temporal denoise for the software ISP.
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

#include <vector>

namespace libcamera {

/**
 * \brief Recursive temporal denoise with a soft motion gate
 *
 * This sensor is noise limited, not resolution limited: trading green
 * resolution against noise in the mosaic conversion leaves detail-to-noise
 * flat, which says the photons - not the algorithm - are the constraint. The
 * only way to get more information out is to use more photons, and the cheapest
 * source of those is the previous frame.
 *
 * Each sample is mixed toward its own history:
 *
 *     out = prev + w * (cur - prev)
 *
 * with w falling to \a alpha where the sample is unchanged and rising to 1
 * where it has moved:
 *
 *     w = alpha + (1 - alpha) * min(1, |cur - prev| / threshold)
 *
 * A hard threshold would be cheaper but it switches per sample, and because the
 * switching is driven by noise it sparkles in exactly the flat areas this is
 * meant to clean up. The ramp costs one multiply and does not.
 *
 * In still areas the recursion converges to a noise reduction of
 * sqrt(alpha / (2 - alpha)): 0.25 gives 2.6x, 0.5 gives 1.7x. Moving areas fall
 * back to the current frame and are neither cleaned nor smeared, which is the
 * right trade for video calls, where most of the frame is wall.
 *
 * \a threshold must sit above the noise floor or noise reads as motion and
 * nothing is ever averaged. Measured floor here is 6.6 to 9.4 counts at 10 bits
 * depending on the sharpness setting, so the default is well clear of it.
 */
class TemporalDenoise
{
public:
	/**
	 * \param[in] alpha Weight of the current frame where nothing moved,
	 *	0 < alpha <= 1. Lower denoises harder. 1 disables.
	 * \param[in] threshold Difference, in raw counts, at which a sample is
	 *	taken as moving and passed through untouched.
	 */
	void configure(float alpha, uint16_t threshold);

	/**
	 * \brief Tell the filter the frame geometry
	 *
	 * Without this, motion is decided over runs of consecutive samples, which
	 * at this width is a horizontal STRIP about a fifth of a row wide, not a
	 * compact region. A moving edge then updates some strips and not others
	 * and leaves horizontal seams across it - the artefact reads as
	 * interlacing combing. With the geometry known the same decision is made
	 * over square tiles instead.
	 */
	void setGeometry(unsigned int width, unsigned int height)
	{
		width_ = width;
		height_ = height;
	}

	/**
	 * \brief Tell the filter how much the noise has been amplified, and where
	 *
	 * Lens shading is applied before this runs, and it multiplies the corners
	 * of this sensor by up to 3.5x - signal AND noise alike. The motion test
	 * is a single threshold in raw counts, so amplified corner noise sails
	 * past it, every corner tile is classified as moving, and the filter
	 * passes it straight through. Measured on this hardware: temporal noise
	 * 1.11 at the centre against 3.43 in the corner, where turning shading
	 * off gave 1.06 in BOTH. The denoise was doing nothing over most of the
	 * frame area, which is most of what a viewer sees.
	 *
	 * Raising the threshold is not the fix. At 140 the corners came right
	 * (3.43 -> 1.81) and the centre went to 6.16, because real motion then
	 * fell under the threshold and got averaged into a smear.
	 *
	 * So divide the known amplification back out: each tile's motion is
	 * scaled by the gain applied there, and the threshold and noise floor
	 * then mean the same thing everywhere. \a map is the green plane of the
	 * shading map, spanning the frame; null disables the correction.
	 *
	 * \param[in] rowOffset Absolute frame row of this band's first row, since
	 *	the caller may pass only the band it converted.
	 */
	void setGainMap(const uint16_t *map, unsigned int mapW, unsigned int mapH,
			uint16_t one, unsigned int frameW, unsigned int frameH,
			unsigned int rowOffset);

	/** \brief Denoise \a frame of \a count samples in place */
	void apply(uint16_t *frame, size_t count);

	/** \brief Forget the history, e.g. after a mode change */
	void reset() { history_.clear(); }

	/** \brief Fraction of blocks treated as moving by the last apply() */
	float lastMotionFraction() const { return motionFraction_; }

private:
	/* Recompute the per-tile gain; cheap, and only on a geometry change. */
	void buildTileScale(unsigned int tx, unsigned int ty);

	static constexpr unsigned int kBlock = 256;   /* fallback when geometry is unknown */
	static constexpr unsigned int kTile = 32;     /* square tile side, in samples */

	unsigned int width_ = 0;
	unsigned int height_ = 0;
	std::vector<uint16_t> history_;
	std::vector<uint16_t> blockMotion_;
	std::vector<uint16_t> scratch_;
	/* Per-tile blend weight, 0-256, blended bilinearly across the frame. */
	std::vector<int32_t> weights_;
	/* Vertically blended weights, one per tile column, rebuilt each row. */
	std::vector<int32_t> vcol_;
	/* Per-tile gain, 8.8 fixed point, 256 = unity. Rebuilt only on change. */
	std::vector<uint16_t> tileScale_;
	const uint16_t *gainMap_ = nullptr;
	unsigned int gainMapW_ = 0;
	unsigned int gainMapH_ = 0;
	unsigned int frameW_ = 0;
	unsigned int frameH_ = 0;
	unsigned int rowOffset_ = 0;
	uint16_t gainOne_ = 0;
	bool gainDirty_ = true;
	float alpha_ = 1.0f;
	uint16_t threshold_ = 32;
	float motionFraction_ = 0.0f;
};

} /* namespace libcamera */
