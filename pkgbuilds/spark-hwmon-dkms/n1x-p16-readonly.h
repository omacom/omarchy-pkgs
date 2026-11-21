/* SPDX-License-Identifier: GPL-2.0 */
#ifndef SPBM_N1X_P16_READONLY_H
#define SPBM_N1X_P16_READONLY_H

static inline bool n1x_p16_probe_has_sensors(bool acpi_power, bool acpi_temp,
                                           bool validated_p16_mmio)
{
    return acpi_power || acpi_temp || validated_p16_mmio;
}

static inline bool n1x_p16_power_value(u32 milliwatts, long *microwatts)
{
    if (milliwatts > 1000000)
        return false;
    *microwatts = (long)milliwatts * 1000;
    return true;
}
#endif
