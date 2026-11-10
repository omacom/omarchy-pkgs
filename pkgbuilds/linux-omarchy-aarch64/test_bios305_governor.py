#!/usr/bin/env python3
"""Exercise the actual system governor with BIOS305 timing sentinels."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

kernel = Path(sys.argv[1])
source = kernel / "drivers/pmdomain/governor.c"
text = source.read_text()
match = re.search(r"static bool cpu_system_power_down_ok\([^;]+?\)\n\{", text)
assert match
end, depth = match.end(), 1
while depth:
    depth += (text[end] == "{") - (text[end] == "}")
    end += 1
function = text[match.start():end]
# Copy the kernel's object-like definitions, including their dependency chain.
def definition(path, name):
    matches = re.findall(r"^#define[ \t]+" + re.escape(name) + r"[ \t]+([^\n]+)$",
                         path.read_text(), re.MULTILINE)
    assert len(matches) == 1, (path, name)
    return "#define " + name + " " + matches[0] + "\n"

constants = definition(kernel / "include/linux/limits.h", "S32_MAX")
for name in ("PM_QOS_LATENCY_ANY", "PM_QOS_LATENCY_ANY_NS",
             "PM_QOS_RESUME_LATENCY_NO_CONSTRAINT",
             "PM_QOS_RESUME_LATENCY_NO_CONSTRAINT_NS"):
    constants += definition(kernel / "include/linux/pm_qos.h", name)
program = r'''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
typedef int32_t s32;
typedef int64_t s64;
#define U32_MAX UINT32_MAX
#define NSEC_PER_USEC 1000
#define GENPD_FLAG_CPU_DOMAIN 1
struct genpd_power_state {s64 power_off_latency_ns,power_on_latency_ns;bool disable;};
struct dev_pm_domain {int unused;};
struct generic_pm_domain {struct dev_pm_domain domain;unsigned int flags;int state_count,state_idx;struct genpd_power_state *states;};
static s32 qos;
static s32 cpu_wakeup_latency_qos_limit(void){return qos;}
static struct generic_pm_domain *pd_to_genpd(struct dev_pm_domain *pd){return (struct generic_pm_domain *)pd;}
'''
program += constants + function
program += r'''
#define CHECK(condition) do { if (!(condition)) return 1; } while (0)
int main(void){
 _Static_assert(PM_QOS_RESUME_LATENCY_NO_CONSTRAINT == INT32_MAX, "kernel QoS sentinel");
 _Static_assert(PM_QOS_RESUME_LATENCY_NO_CONSTRAINT_NS == 2147483647000LL, "finite sentinel ns");
 struct genpd_power_state states[1]={{.power_on_latency_ns=(int64_t)UINT32_MAX*1000}};
 struct generic_pm_domain domain={.flags=GENPD_FLAG_CPU_DOMAIN,.state_count=1,.states=states};
 CHECK(states[0].power_on_latency_ns==4294967295000LL);
 qos=PM_QOS_RESUME_LATENCY_NO_CONSTRAINT;
 CHECK(cpu_system_power_down_ok(&domain.domain));CHECK(domain.state_idx==0);
 qos=10000;CHECK(!cpu_system_power_down_ok(&domain.domain));
 qos=INT32_MAX-1;CHECK(!cpu_system_power_down_ok(&domain.domain));
 qos=PM_QOS_RESUME_LATENCY_NO_CONSTRAINT;states[0].disable=true;
 CHECK(!cpu_system_power_down_ok(&domain.domain));
 return 0;
}
'''
with tempfile.TemporaryDirectory() as directory:
    target = Path(directory)
    def run(body):
        (target / "test.c").write_text(body)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-fsanitize=address,undefined", str(target / "test.c"),
                        "-o", str(target / "test")], check=True)
        return subprocess.run([str(target / "test")], check=False).returncode
    assert run(program) == 0, "actual governor rejected expected QoS behavior"
    guard = "no_constraint || latency_ns <= constraint_ns"
    assert function.count(guard) == 1, "expected actual no-constraint guard"
    mutated = program.replace(guard, "latency_ns <= constraint_ns", 1)
    assert run(mutated) == 1, "missing no-constraint exception escaped regression"
print("PASS actual kernel QoS constants, sentinel/finite/disabled cases; removed exception rejected")
