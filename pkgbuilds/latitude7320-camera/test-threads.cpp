/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * Threading must not change a single pixel.
 *
 * convertSharp() splits the frame into horizontal bands across threads. Each
 * band writes only its own output rows, and the chroma blur that reads across
 * band boundaries is separated from the first pass by a barrier - so the
 * result should be bit identical to the single-threaded path, not merely
 * similar. Anything else means a band is reading or writing outside itself,
 * and the visible symptom would be a seam at every band boundary.
 *
 * The IR statistics are integer sums, so merging them per band is exact too;
 * they are compared through effectiveIrSubtract(), which is what the next
 * frame would act on.
 *
 * Build:
 *   g++ -O2 -std=c++17 -o /tmp/test-threads test-threads.cpp rgbir_to_bayer.cpp -lpthread
 */

#include "rgbir_to_bayer.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <random>
#include <vector>

using namespace libcamera;

int main()
{
	/* The real sensor geometry, so band splitting sees the real row count. */
	const unsigned int w = 2592, h = 1944;
	const unsigned int srcStride = w * 2;
	const unsigned int dstStride = (w / 2) * 2;

	/*
	 * Deterministic pseudo-random data with a strong vertical gradient. Flat
	 * noise would hide a band that read a neighbour's rows; a gradient makes
	 * any such read land visibly wrong.
	 */
	std::vector<uint16_t> src((size_t)w * h);
	std::mt19937 rng(12345);
	for (unsigned int y = 0; y < h; y++)
		for (unsigned int x = 0; x < w; x++)
			src[(size_t)y * w + x] =
				(uint16_t)(64 + (y * 700) / h + (rng() % 220));

	const RgbIrToBayer::Channel pattern[16] = {
		RgbIrToBayer::Green, RgbIrToBayer::Infrared, RgbIrToBayer::Green, RgbIrToBayer::Infrared,
		RgbIrToBayer::Red,   RgbIrToBayer::Green,    RgbIrToBayer::Blue,  RgbIrToBayer::Green,
		RgbIrToBayer::Green, RgbIrToBayer::Infrared, RgbIrToBayer::Green, RgbIrToBayer::Infrared,
		RgbIrToBayer::Blue,  RgbIrToBayer::Green,    RgbIrToBayer::Red,   RgbIrToBayer::Green,
	};

	std::vector<uint16_t> shadeG((size_t)17 * 13), shadeR(17 * 13),
			      shadeB(17 * 13), shadeI(17 * 13);
	for (size_t i = 0; i < shadeG.size(); i++) {
		shadeG[i] = (uint16_t)(1024 + (i % 7) * 90);
		shadeR[i] = (uint16_t)(1024 + (i % 5) * 130);
		shadeB[i] = (uint16_t)(1024 + (i % 11) * 70);
		shadeI[i] = 1024;
	}
	RgbIrToBayer::ShadingMap shading{};
	shading.gains[RgbIrToBayer::Green] = shadeG.data();
	shading.gains[RgbIrToBayer::Red] = shadeR.data();
	shading.gains[RgbIrToBayer::Blue] = shadeB.data();
	shading.gains[RgbIrToBayer::Infrared] = shadeI.data();
	shading.width = 17;
	shading.height = 13;
	shading.one = 1024;

	int failures = 0;

	/* Every combination that changes which code path runs. */
	for (int blur : { 0, 1, 2 }) {
		for (int shade : { 0, 1 }) {
			for (int band : { 0, 1 }) {
				std::vector<uint16_t> ref((size_t)(w / 2) * (h / 2), 0);
				float refIr = 0.0f;

				for (unsigned int threads : { 1u, 2u, 3u, 4u, 8u }) {
					RgbIrToBayer conv(pattern, 64, 10);
					conv.setIrSubtract(1.0f);
					conv.setIrAdaptive(true);
					conv.setChromaBlur(blur);
					conv.setSharpness(0.0f);
					if (band)
						conv.setActiveRows(126, 846);
					conv.setThreads(threads);

					std::vector<uint16_t> dst((size_t)(w / 2) * (h / 2), 0);
					int ret = conv.convertSharp(
						(const uint8_t *)src.data(), w, h,
						srcStride, dst.data(), dstStride,
						RgbIrToBayer::Order::GBRG,
						shade ? &shading : nullptr);
					if (ret != 0) {
						printf("FAIL convertSharp returned %d\n", ret);
						failures++;
						continue;
					}

					if (threads == 1) {
						ref = dst;
						refIr = conv.effectiveIrSubtract();
						continue;
					}

					size_t diff = 0, firstRow = 0;
					for (size_t i = 0; i < dst.size(); i++) {
						if (dst[i] != ref[i]) {
							if (!diff)
								firstRow = i / (w / 2);
							diff++;
						}
					}
					const bool irSame = conv.effectiveIrSubtract() == refIr;
					if (diff || !irSame) {
						printf("FAIL blur=%d shade=%d band=%d threads=%u: "
						       "%zu pixels differ (first at row %zu), ir %.6f vs %.6f\n",
						       blur, shade, band, threads, diff, firstRow,
						       conv.effectiveIrSubtract(), refIr);
						failures++;
					} else {
						printf("ok   blur=%d shade=%d band=%d threads=%u\n",
						       blur, shade, band, threads);
					}
				}
			}
		}
	}

	printf("\n%s\n", failures ? "FAILURES" : "all identical to the single-threaded path");
	return failures ? 1 : 0;
}
