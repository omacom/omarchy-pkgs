#!/usr/bin/env python3
"""Compile real CPPC parser/restore callbacks with deterministic hardware stubs."""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]) / "drivers/cpufreq/cppc_cpufreq.c"
text = source.read_text()


def function(name):
    pos = text.index(name + "(")
    start = text.rfind("\nstatic ", 0, pos) + 1
    brace = text.index("{", pos)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


modes = text[text.index("/* Autonomous Selection boot parameter modes */"):
             text.index("static int auto_sel_mode_set(")]
saved_enum = text[text.index("enum cppc_saved_reg_id {"):
                  text.index("struct cppc_saved_reg {")]
type_enum = text[text.index("enum cppc_saved_type {"):
                 text.index("/*\n * Per-policy values saved")]
harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t u64;
#define U64_MAX UINT64_MAX
#define pr_warn(...) ((void)0)
struct kernel_param { void *arg; };
static int match(const char *const *names, size_t n, const char *value) {
    size_t len = strlen(value);
    if (len && value[len - 1] == '\n') len--;
    for (size_t i = 0; i < n; ++i)
        if (strlen(names[i]) == len && !strncmp(names[i], value, len)) return i;
    return -1;
}
#define sysfs_match_string(a, v) match(a, sizeof(a)/sizeof((a)[0]), v)
'''
harness += saved_enum + type_enum + modes + function("auto_sel_mode_set")
harness += r'''
struct cppc_policy_state { u64 regs[CPPC_NR_SAVED_REGS][CPPC_NR_SAVED_TYPES]; bool suspend_regs_handled; };
struct cpufreq_policy { unsigned int cpu; };
static struct cppc_policy_state state;
static int writes[16], nwrites, fie_exits, online_calls, apply_calls;
static struct cppc_policy_state *cppc_cpufreq_policy_state(struct cpufreq_policy *p) { (void)p; return &state; }
static void cppc_cpufreq_write_saved_reg(unsigned int cpu, enum cppc_saved_reg_id reg, u64 val, enum cppc_saved_type type) {
    (void)cpu; (void)type;
    if (val != U64_MAX) writes[nwrites++] = reg;
}
'''
harness += function("cppc_cpufreq_apply_saved_regs")
harness += r'''
static void cppc_cpufreq_cpu_fie_exit(struct cpufreq_policy *p) { (void)p; fie_exits++; }
static int cppc_cpufreq_cpu_online(struct cpufreq_policy *p) { (void)p; online_calls++; state.suspend_regs_handled = false; return 0; }
'''
harness += function("cppc_cpufreq_cpu_suspend") + function("cppc_cpufreq_cpu_resume")
harness += r'''
int main(void) {
    struct kernel_param kp = {.arg = &auto_sel_mode};
    assert(auto_sel_mode == AUTO_SEL_MODE_DISABLED);
    for (int i = 0; i < 6; ++i) {
        assert(!auto_sel_mode_set(auto_sel_mode_names[i], &kp));
        assert(auto_sel_mode == i);
    }
    assert(!auto_sel_mode_set("balance_power\n", &kp));
    assert(auto_sel_mode == AUTO_SEL_MODE_BALANCE_POWER);
    const char *invalid[] = {"1", "0", "true", "invalid", ""};
    for (unsigned int i = 0; i < sizeof(invalid)/sizeof(*invalid); ++i) {
        auto_sel_mode = AUTO_SEL_MODE_DISABLED;
        assert(!auto_sel_mode_set(invalid[i], &kp));
        assert(auto_sel_mode == AUTO_SEL_MODE_DISABLED);
    }
    struct cpufreq_policy policy = {.cpu = 3};
    for (int type = 0; type < CPPC_NR_SAVED_TYPES; ++type) {
        for (int enabled = 0; enabled < 2; ++enabled) {
            memset(&state, 0, sizeof(state));
            state.regs[CPPC_SAVED_AUTO_SEL][type] = enabled;
            nwrites = 0;
            cppc_cpufreq_apply_saved_regs(&policy, type);
            assert(nwrites == 4);
            assert(writes[0] == CPPC_SAVED_OSPM_NOMINAL_PERF);
            assert(writes[enabled ? 1 : 3] == CPPC_SAVED_AUTO_SEL);
            assert(writes[enabled ? 2 : 1] == CPPC_SAVED_EPP);
            assert(writes[enabled ? 3 : 2] == CPPC_SAVED_AUTO_ACT_WINDOW);
        }
    }
    memset(&state, 0xff, sizeof(state));
    nwrites = 0;
    cppc_cpufreq_apply_saved_regs(&policy, CPPC_SAVED_REQUESTED);
    assert(!nwrites);
    memset(&state, 0, sizeof(state));
    assert(!cppc_cpufreq_cpu_resume(&policy) && !online_calls);
    assert(!cppc_cpufreq_cpu_suspend(&policy));
    assert(state.suspend_regs_handled && fie_exits == 1);
    assert(!cppc_cpufreq_cpu_resume(&policy));
    assert(!state.suspend_regs_handled && online_calls == 1);
    assert(!cppc_cpufreq_cpu_resume(&policy) && online_calls == 1);
    puts("PASS: six named modes, legacy rejection, firmware/requested restore ordering, unsupported registers, suspend/resume callbacks");
}
'''
with tempfile.TemporaryDirectory(prefix="cppc-regression-") as temp:
    cfile = pathlib.Path(temp) / "cppc.c"
    exe = pathlib.Path(temp) / "cppc"
    cfile.write_text(harness)
    subprocess.run(["cc", "-std=gnu11", "-O1", "-g", "-fsanitize=undefined,address",
                    str(cfile), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
