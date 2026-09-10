#!/usr/bin/env python3
"""Test native CVS power ownership using real driver functions and fake transport.

Pass a kernel source directory. No camera devices or network are accessed.
The original Linux 7.2.3 source fails the PTL policy; the package patch passes.
"""
import argparse
import pathlib
import re
import subprocess
import tempfile


def extract(source, start, end):
    begin = source.index(start)
    finish = source.index(end, begin) + len(end)
    return source[begin:finish]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_source', type=pathlib.Path)
    args = parser.parse_args()
    directory = args.kernel_source / 'drivers/media/i2c/cvs'
    source = (directory / 'core.c').read_text()
    header = (directory / 'icvs.h').read_text()
    constants = '\n'.join(re.findall(
        r'^#define ICVS_\w+[^\n]*\b(?:BIT|GENMASK)\([^\n]*', header, re.MULTILINE))
    code = [
        PREAMBLE,
        constants,
        extract(header, 'enum icvs_command {', '\n};'),
        extract(header, 'struct icvs_device_quirk {', '\n};'),
        extract(source, 'static const struct icvs_device_quirk cvs_quirk_table[]', '\n};'),
        extract(source, 'static void cvs_set_quirks(', '\n}'),
        extract(source, 'static int cvs_configure_dev_caps(', '\n}'),
        CASES,
    ]
    with tempfile.TemporaryDirectory(prefix='native-cvs-power-') as temporary:
        test = pathlib.Path(temporary) / 'power.c'
        binary = pathlib.Path(temporary) / 'power'
        test.write_text('\n'.join(code))
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        str(test), '-o', str(binary)], check=True)
        return subprocess.run([str(binary)], check=False).returncode


PREAMBLE = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint16_t u16;
#define BIT(x) (1UL << (x))
#define GENMASK(h, l) ((~0UL << (l)) & (~0UL >> (sizeof(unsigned long) * 8 - 1 - (h))))
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define dev_info(...) ((void)0)
#define guard(x) (void)
/* Endianness is irrelevant to the ownership mask being tested. */
#define cpu_to_be16(x) (x)
struct acpi_device { const char *hid; };
struct device { struct acpi_device *acpi; };
struct icvs { unsigned long quirks; struct device dev; int lock; };
struct icvs_cmd { u16 cmd_id; struct { uint32_t host_id; } param; };
#define cvs_dev(ctx) (&(ctx)->dev)
#define ACPI_COMPANION(dev) ((dev)->acpi)
#define has_acpi_companion(dev) (ACPI_COMPANION(dev) != NULL)
#define acpi_dev_hid_match(adev, wanted_hid) (strcmp((adev)->hid, (wanted_hid)) == 0)
static uint32_t sent;
static unsigned sends;
static int cvs_send(struct icvs *ctx, struct icvs_cmd *cmd, size_t size)
{
    (void)ctx;
    (void)size;
    sent = cmd->param.host_id;
    sends++;
    return 0;
}
static void require(bool condition, const char *name, const char *reason)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s: %s\n", name, reason);
        exit(EXIT_FAILURE);
    }
}
'''

CASES = r'''
int main(void)
{
    const struct {
        const char *name;
        const char *hid;
        u16 vid, pid;
        bool host_power;
        bool host_privacy;
        bool no_caps;
    } cases[] = {
        { "PTL Synaptics", "INTC10E1", 0x06cb, 0x0701, false, true, false },
        { "LNL Synaptics", "INTC10DE", 0x06cb, 0x0701, true, true, false },
        { "ARL Synaptics", "INTC10E0", 0x06cb, 0x0701, true, true, false },
        { "unverified E2", "INTC10E2", 0x06cb, 0x0701, true, true, false },
        { "NVL Synaptics", "INTC10FA", 0x06cb, 0x0701, true, true, false },
        { "no ACPI", NULL, 0x06cb, 0x0701, true, true, false },
        { "PTL Lattice", "INTC10E1", 0x2ac1, 0x20d0, false, false, true },
        { "PTL other vendor", "INTC10E1", 0x1234, 0x0701, false, false, false },
        { "PTL other product", "INTC10E1", 0x06cb, 0x1234, false, false, false },
    };
    for (size_t i = 0; i < ARRAY_SIZE(cases); i++) {
        struct acpi_device acpi = { cases[i].hid };
        struct icvs ctx = { .dev = { cases[i].hid ? &acpi : NULL } };
        /* Probe and resume both initialise the quirk mask afresh. */
        for (unsigned cycle = 0; cycle < 2; cycle++) {
            ctx.quirks = ~0UL;
            cvs_set_quirks(&ctx, cases[i].vid, cases[i].pid);
            require(!!(ctx.quirks & ICVS_HOST_SENSOR_PWR_CTRL) == cases[i].host_power,
                    cases[i].name, "sensor power ownership");
            require(!!(ctx.quirks & ICVS_HOST_PRIV_CTRL) == cases[i].host_privacy,
                    cases[i].name, "privacy ownership changed");
            unsigned long expected_quirks = 0;
            if (cases[i].vid == 0x06cb && cases[i].pid == 0x0701) {
                expected_quirks = ICVS_SKIP_FW_RESET | ICVS_FW_BUF_SIZE_256 |
                                  ICVS_FW_HEADER_SIZE_256 | ICVS_HOST_PRIV_CTRL;
                if (cases[i].host_power)
                    expected_quirks |= ICVS_HOST_SENSOR_PWR_CTRL;
            } else if (cases[i].no_caps) {
                expected_quirks = ICVS_NO_MIPI_CONFIG | ICVS_NO_CAPS | ICVS_NO_FW_UPDATE;
            }
            require(ctx.quirks == expected_quirks, cases[i].name, "unrelated quirks changed");
            sends = 0;
            sent = UINT32_MAX;
            require(cvs_configure_dev_caps(&ctx) == 0, cases[i].name, "command failed");
            require(sends == (cases[i].no_caps ? 0U : 1U), cases[i].name, "command count");
            if (!cases[i].no_caps) {
                uint32_t expected = cases[i].host_power ? ICVS_HOST_ID_RGBCAMERA_PWRUP : 0;
                if (cases[i].host_privacy)
                    expected |= ICVS_HOST_ID_PRIVACY_LED;
                require(sent == expected, cases[i].name, "host identifier command");
            }
        }
    }
    puts("PASS: 9 CVS ownership cases, each after probe and resume quirk resets");
    return 0;
}
'''

if __name__ == '__main__':
    raise SystemExit(main())
