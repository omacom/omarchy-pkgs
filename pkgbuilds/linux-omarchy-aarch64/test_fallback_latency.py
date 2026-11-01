#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compile the actual setup and cpuidle selection functions with C mocks."""

import argparse
import pathlib
import subprocess
import tempfile


def extract_function(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


MOCKS = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
typedef uint32_t u32;
typedef uint64_t u64;
#define U32_MAX UINT32_MAX
#define NSEC_PER_USEC 1000U
#define CPUIDLE_STATE_MAX 8
#define CPUIDLE_NAME_LEN 16
#define CPUIDLE_DESC_LEN 32
#define ACPI_CSTATE_FFH 1
#define CPUIDLE_FLAG_RCU_IDLE 1U
#define CONFIG_PREEMPT_RT 0
#define IS_ENABLED(x) (x)
#define per_cpu(name, cpu) (name)
struct cpuidle_device;
struct cpuidle_driver;
typedef int (*enter_fn)(struct cpuidle_device *, struct cpuidle_driver *, int);
struct acpi_lpi_state {
    u32 wake_latency, min_residency, arch_flags;
    int entry_method;
    char desc[CPUIDLE_DESC_LEN];
};
struct cpuidle_state {
    unsigned int exit_latency, target_residency, flags;
    u64 exit_latency_ns, target_residency_ns;
    char name[CPUIDLE_NAME_LEN], desc[CPUIDLE_DESC_LEN];
    enter_fn enter, enter_s2idle;
};
struct cpuidle_driver {
    struct cpuidle_state states[CPUIDLE_STATE_MAX];
    int state_count, safe_state_index;
};
struct cpuidle_device {
    struct { unsigned int disable; } states_usage[CPUIDLE_STATE_MAX];
};
struct acpi_processor {
    int id;
    struct { bool has_lpi; } flags;
    struct { unsigned int count; struct acpi_lpi_state lpi_states[8]; } power;
};
struct acpi_lpi_runtime_state {
    struct acpi_lpi_state state;
    struct acpi_lpi_runtime_state *next;
};
struct acpi_idle_data {
    bool base_map_entry;
    unsigned int leaf_lpi_count;
    struct acpi_lpi_runtime_state *runtime_states;
};
static struct acpi_idle_data *acpi_idle_data;
static bool n1x_present;
#define list_for_each_entry(pos, head, member) \
    for ((pos) = *(head); (pos); (pos) = (pos)->next)
static bool acpi_dev_present(const char *hid, const char *uid, long long hrv)
{
    if (strcmp(hid, "NVDA6210") || uid || hrv != -1)
        abort();
    return n1x_present;
}
static void strscpy(char *dst, const char *src, size_t size)
{
    if (size)
        snprintf(dst, size, "%s", src);
}
static u64 mul_u32_u32(u32 a, u32 b) { return (u64)a * b; }
static unsigned int arch_get_idle_state_flags(u32 flags) { return flags; }
static bool acpi_processor_ffh_lpi_is_wfi(const struct acpi_lpi_state *lpi)
{
    return lpi->wake_latency == 0;
}
#define CALLBACK(name) \
    static int name(struct cpuidle_device *dev, struct cpuidle_driver *drv, int i) \
    { (void)dev; (void)drv; return i; }
CALLBACK(acpi_idle_lpi_enter_leaf)
CALLBACK(acpi_idle_lpi_enter_direct)
CALLBACK(acpi_idle_lpi_enter_s2idle)
CALLBACK(acpi_idle_lpi_enter_domain)
'''

TESTS = r'''
static int failures;
static void check(const char *name, bool ok)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    failures += !ok;
}
static void run_case(const char *name, bool coordinated, bool present,
                     u32 residency, unsigned int expected_latency,
                     int expected_selected)
{
    struct acpi_processor pr = { .flags.has_lpi = true, .power.count = 3 };
    struct acpi_idle_data data = { .base_map_entry = true, .leaf_lpi_count = 3 };
    struct cpuidle_driver drv = { 0 };
    struct cpuidle_device dev = { 0 };
    unsigned int i;

    pr.power.lpi_states[1].wake_latency = 967;
    pr.power.lpi_states[1].min_residency = 2000;
    pr.power.lpi_states[2].wake_latency = 966;
    pr.power.lpi_states[2].min_residency = residency;
    for (i = 0; i < 3; i++)
        pr.power.lpi_states[i].entry_method = ACPI_CSTATE_FFH;
    acpi_idle_data = coordinated ? &data : NULL;
    n1x_present = present;
    acpi_processor_setup_lpi_states(&pr, &drv, coordinated);

    printf("%s: package=%u us DRIPS=%u us selected=%d residency=%u\n",
           name, drv.states[1].exit_latency, drv.states[2].exit_latency,
           find_deepest_state(&drv, &dev, UINT64_MAX, 0, true),
           drv.states[2].target_residency);
    check(name, drv.state_count == 3 &&
          drv.states[0].exit_latency == 0 &&
          drv.states[0].exit_latency_ns == 0 &&
          drv.states[1].exit_latency == 967 &&
          drv.states[1].exit_latency_ns == 967000 &&
          drv.states[2].exit_latency == expected_latency &&
          drv.states[2].exit_latency_ns == (u64)expected_latency * 1000 &&
          drv.states[2].target_residency == residency &&
          drv.states[2].target_residency_ns == (u64)residency * 1000 &&
          find_deepest_state(&drv, &dev, UINT64_MAX, 0, true) == expected_selected);
    if (coordinated)
        check("coordinated callback retained",
              drv.states[2].enter_s2idle == acpi_idle_lpi_enter_s2idle &&
              drv.states[2].enter == acpi_idle_lpi_enter_domain);
    else
        check("fallback callback retained",
              drv.states[2].enter_s2idle == acpi_idle_lpi_enter_direct &&
              drv.states[2].enter == acpi_idle_lpi_enter_direct);
}
int main(void)
{
    run_case("N1x fallback sentinel selects DRIPS", false, true, U32_MAX, 7576, 2);
    run_case("N1x coordinated sentinel unchanged", true, true, U32_MAX, 966, 2);
    run_case("non-N1x fallback unchanged", false, false, U32_MAX, 966, 1);
    run_case("N1x normal residency unchanged", false, true, 1437, 966, 1);
    run_case("non-N1x coordinated unchanged", true, false, U32_MAX, 966, 2);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("processor_idle", type=pathlib.Path)
    parser.add_argument("cpuidle", type=pathlib.Path)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    source = args.processor_idle.read_text()
    setup = extract_function(source, "static void acpi_processor_setup_lpi_states(")
    constant = ""
    for line in source.splitlines():
        if line.startswith("#define ACPI_N1X_DRIPS_WAKE_LATENCY_US"):
            constant = line + "\n"
    deepest = extract_function(args.cpuidle.read_text(), "static int find_deepest_state(")
    with tempfile.TemporaryDirectory(prefix="n1x-fallback-") as temporary:
        root = pathlib.Path(temporary)
        generated = root / "test.c"
        generated.write_text(MOCKS + constant + setup + "\n" + deepest + TESTS)
        command = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                   "-Wno-unused-function", "-g", "-o", str(root / "test"), str(generated)]
        if args.sanitize:
            command[1:1] = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        subprocess.run(command, check=True)
        return subprocess.run([str(root / "test")]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
