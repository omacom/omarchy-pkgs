#!/usr/bin/env python3
"""Exercise the actual system governor with BIOS305 timing sentinels."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]) / "drivers/pmdomain/governor.c"
text = source.read_text()
match = re.search(r"static bool cpu_system_power_down_ok\([^;]+?\)\n\{", text)
assert match
end, depth = match.end(), 1
while depth:
    depth += (text[end] == "{") - (text[end] == "}")
    end += 1
function = text[match.start():end]
program = r'''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
typedef int32_t s32;
typedef int64_t s64;
#define PM_QOS_RESUME_LATENCY_NO_CONSTRAINT (-1)
#define PM_QOS_RESUME_LATENCY_NO_CONSTRAINT_NS INT64_MAX
#define NSEC_PER_USEC 1000
#define GENPD_FLAG_CPU_DOMAIN 1
struct genpd_power_state {s64 power_off_latency_ns,power_on_latency_ns;bool disable;};
struct dev_pm_domain {int unused;};
struct generic_pm_domain {struct dev_pm_domain domain;unsigned int flags;int state_count,state_idx;struct genpd_power_state *states;};
static s32 qos;
static s32 cpu_wakeup_latency_qos_limit(void){return qos;}
static struct generic_pm_domain *pd_to_genpd(struct dev_pm_domain *pd){return (struct generic_pm_domain *)pd;}
'''
program += function
program += r'''
int main(void){
 struct genpd_power_state states[1]={{.power_on_latency_ns=(int64_t)UINT32_MAX*1000}};
 struct generic_pm_domain domain={.flags=GENPD_FLAG_CPU_DOMAIN,.state_count=1,.states=states};
 assert(states[0].power_on_latency_ns==4294967295000LL);
 qos=PM_QOS_RESUME_LATENCY_NO_CONSTRAINT;
 assert(cpu_system_power_down_ok(&domain.domain));assert(domain.state_idx==0);
 qos=10000;assert(!cpu_system_power_down_ok(&domain.domain));
 qos=INT32_MAX;assert(!cpu_system_power_down_ok(&domain.domain));
 qos=PM_QOS_RESUME_LATENCY_NO_CONSTRAINT;states[0].disable=true;
 assert(!cpu_system_power_down_ok(&domain.domain));
 puts("PASS actual system governor preserves sentinel, finite QoS and disabled-state rejection");
}
'''
with tempfile.TemporaryDirectory() as directory:
    target = Path(directory)
    (target / "test.c").write_text(program)
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", str(target / "test.c"),
                    "-o", str(target / "test")], check=True)
    subprocess.run([str(target / "test")], check=True)
