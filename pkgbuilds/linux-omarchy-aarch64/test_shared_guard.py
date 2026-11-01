#!/usr/bin/env python3
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
s=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text();m=re.search(r'static int acpi_lpi_pd_power_off_s2idle\([^;]+?\)\n\{',s);a,i,d=m.start(),m.end(),1
while d:
 if s[i]=='{':d+=1
 elif s[i]=='}':d-=1
 i+=1
code=r'''
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <stdio.h>
struct generic_pm_domain {int *cpus;};
static int mask,common_calls,selections;static bool sleeping,syscore,offline;
static unsigned int raw_smp_processor_id(void){return 0;}
static bool cpumask_test_cpu(unsigned int cpu,int*m){(void)cpu;return *m;}
static bool idle_should_enter_s2idle(void){return sleeping;}
static int acpi_lpi_pd_power_off(struct generic_pm_domain*d){common_calls++;if(!*d->cpus)return syscore||offline?0:-EXDEV;selections++;return 0;}
'''+s[a:i]+r'''
int main(void){struct generic_pm_domain d={&mask};mask=1;assert(acpi_lpi_pd_power_off_s2idle(&d)==-EBUSY);assert(!common_calls&&!selections);sleeping=true;assert(!acpi_lpi_pd_power_off_s2idle(&d));assert(selections==1);mask=0;sleeping=false;syscore=true;assert(!acpi_lpi_pd_power_off_s2idle(&d));syscore=false;offline=true;assert(!acpi_lpi_pd_power_off_s2idle(&d));offline=false;assert(acpi_lpi_pd_power_off_s2idle(&d)==-EXDEV);assert(selections==1);puts("PASS actual per-domain guard: no runtime shared selection, actual s2idle, nonmember/syscore/offline accounting selects no state");return 0;}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'t.c').write_text(code);subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'t.c'),'-o',str(p/'t')],check=True);subprocess.run([str(p/'t')],check=True)
