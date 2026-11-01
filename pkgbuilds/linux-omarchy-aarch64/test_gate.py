#!/usr/bin/env python3
"""Compile and execute the production admission functions, with firmware stubs."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "integrated-source/drivers/acpi/processor_idle.c"
PCI = ROOT / "integrated-source/drivers/pci/hotplug/pciehp_core.c"

STUBS = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#define __init
#define __setup(a, b)
#define DEFINE_MUTEX(x) int x
#define SHA256_DIGEST_SIZE 32
#define ACPI_SIG_DSDT "DSDT"
#define ACPI_FAILURE(x) (x)
#define DMI_SYS_VENDOR 0
#define DMI_PRODUCT_NAME 1
#define DMI_BIOS_VERSION 2
typedef uint8_t u8;
static const char *fields[3];
static bool has_n1x;
static int bios_reads;
static int table_reads;
struct acpi_table_header { unsigned int length; };
static inline void log_message(const char *fmt, ...)
{ (void)fmt; }
#define pr_info log_message
#define pr_warn log_message
static inline void mutex_lock(int *x) { (void)x; }
static inline void mutex_unlock(int *x) { (void)x; }
static inline const char *dmi_get_system_info(int field)
{ if (field == DMI_BIOS_VERSION) bios_reads++; return fields[field]; }
static inline bool dmi_match(int field, const char *value)
{ const char *s = dmi_get_system_info(field); return s && !strcmp(s, value); }
static inline bool acpi_dev_present(const char *id, const char *uid, int rev)
{ (void)uid; (void)rev; return !strcmp(id, "NVDA6210") && has_n1x; }
static inline int acpi_get_table(const char *sig, int n, struct acpi_table_header **t)
{ static struct acpi_table_header table = { 73551 }; table_reads++; (void)sig; (void)n; *t = &table; return 0; }
static inline void acpi_put_table(struct acpi_table_header *t) { (void)t; }
static inline void sha256(const u8 *s, size_t n, u8 *digest)
{ static const u8 hash[32] = {0x5e,0xce,0xd7,0x5d,0x1b,0x24,0xc7,0xfb,
0xd0,0x69,0xaa,0x92,0x40,0x69,0x51,0x47,0x84,0x8b,0xbf,0xca,0x56,0xcc,
0xe7,0x6a,0xb7,0xf4,0xa6,0xa0,0xeb,0xa9,0x84,0x9f};
(void)s; (void)n; memcpy(digest, hash, 32); }
'''

MAIN = r'''
int main(int argc, char **argv)
{
    bool allowed;
    if (argc != 6) return 2;
    fields[0] = strcmp(argv[1], "@NULL") ? argv[1] : NULL;
    fields[1] = strcmp(argv[2], "@NULL") ? argv[2] : NULL;
    fields[2] = argv[3];
    has_n1x = atoi(argv[4]);
    if (strcmp(argv[5], "@ABSENT"))
        n1x_coordinated_setup(strcmp(argv[5], "@NULL") ? argv[5] : NULL);
    allowed = n1x_coordinated_allowed();
    printf("%d %d %d %d\n", allowed, n1x_coordinated_requested, bios_reads, table_reads);
    return 0;
}
'''


class AutomaticGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        text = SOURCE.read_text()
        gate = text[text.index("static bool n1x_coordinated_requested;"):
                    text.index("struct acpi_lpi_genpd_map_entry {")]
        cfile = Path(cls.tmp.name) / "gate.c"
        cls.binary = Path(cls.tmp.name) / "gate"
        cfile.write_text(STUBS + gate + MAIN)
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall",
                        "-Wextra", "-Werror", str(cfile), "-o", str(cls.binary)],
                       check=True, capture_output=True, text=True)

    def check_gate(self, expected, vendor="ASUS", product="ProArt P16 H7607BA",
                   bios="H7607BA.303", n1x=True, arg="@ABSENT"):
        result = subprocess.run([str(self.binary), vendor, product, bios,
                                 str(int(n1x)), arg], check=True,
                                capture_output=True, text=True)
        self.assertEqual(tuple(map(int, result.stdout.split())),
                         (int(expected), int(expected), 0, 0))

    def test_no_argument_activates(self):
        self.check_gate(True)

    def test_no_bios_or_model_code_pin(self):
        for bios, product in [("H7607BA.304", "ProArt P16 H7607BA"),
                              ("future", "ProArt P16 H9999"),
                              ("", "ProArt P16")]:
            with self.subTest(bios=bios, product=product):
                self.check_gate(True, bios=bios, product=product)

    def test_other_hardware_refused(self):
        for args in [{"vendor": "Other"}, {"vendor": "@NULL"},
                     {"product": "ProArt P14 H7607BA"}, {"n1x": False},
                     {"product": "ProArt P160 H7607BA"},
                     {"product": "ProArt P16X"}, {"product": "@NULL"},
                     {"product": "Unrelated ProArt P16"}]:
            with self.subTest(**args):
                self.check_gate(False, **args)

    def test_zero_disables(self):
        self.check_gate(False, arg="0")

    def test_one_does_not_force_hardware(self):
        self.check_gate(True, arg="1")
        self.check_gate(False, arg="1", product="ProArt P14")
        self.check_gate(False, arg="1", n1x=False)

    def test_malformed_disables(self):
        for value in ["", "@NULL", "2", "yes", "true", "01", "1junk"]:
            with self.subTest(value=value):
                self.check_gate(False, arg=value)


class PciPlatformGate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        text = PCI.read_text()
        gate = text[text.index("static bool pciehp_p16_n1x_matches(void)"):
                    text.index("/* This soldered reader")]
        main = r'''
int main(int argc, char **argv)
{
    if (argc != 5) return 2;
    fields[0] = strcmp(argv[1], "@NULL") ? argv[1] : NULL;
    fields[1] = strcmp(argv[2], "@NULL") ? argv[2] : NULL;
    fields[2] = argv[3];
    has_n1x = atoi(argv[4]);
    printf("%d %d %d\n", pciehp_p16_n1x_matches(), bios_reads, table_reads);
    return 0;
}
'''
        cfile = Path(cls.tmp.name) / "pci_gate.c"
        cls.binary = Path(cls.tmp.name) / "pci_gate"
        cfile.write_text(STUBS + gate + main)
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall",
                        "-Wextra", "-Werror", str(cfile), "-o", str(cls.binary)],
                       check=True, capture_output=True, text=True)

    def check_gate(self, expected, vendor="ASUS", product="ProArt P16 H7607BA",
                   bios="H7607BA.303", n1x=True):
        result = subprocess.run([str(self.binary), vendor, product, bios,
                                 str(int(n1x))], check=True,
                                capture_output=True, text=True)
        self.assertEqual(tuple(map(int, result.stdout.split())),
                         (int(expected), 0, 0))

    def test_matching_n1x_without_bios_or_model_pin(self):
        for bios, product in [("H7607BA.303", "ProArt P16 H7607BA"),
                              ("next", "ProArt P16 H9999"), ("", "ProArt P16")]:
            with self.subTest(bios=bios, product=product):
                self.check_gate(True, bios=bios, product=product)

    def test_other_hardware_refused(self):
        for args in [{"vendor": "Other"}, {"vendor": "@NULL"},
                     {"product": "ProArt P14"}, {"n1x": False},
                     {"product": "ProArt P160"}, {"product": "ProArt P16X"},
                     {"product": "@NULL"}]:
            with self.subTest(**args):
                self.check_gate(False, **args)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--processor-source", type=Path, default=SOURCE)
    parser.add_argument("--pci-source", type=Path, default=PCI)
    options, remaining = parser.parse_known_args()
    SOURCE, PCI = options.processor_source, options.pci_source
    unittest.main(argv=[sys.argv[0], *remaining])
