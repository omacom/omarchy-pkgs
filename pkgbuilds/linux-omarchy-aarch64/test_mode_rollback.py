#!/usr/bin/env python3
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
s=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text();m=re.search(r'static int acpi_lpi_deactivate_locked\([^;]+?\)\n\{',s);a,i,d=m.start(),m.end(),1
while d:
 if s[i]=='{':d+=1
 elif s[i]=='}':d-=1
 i+=1
prefix=r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
typedef int *cpumask_var_t;
static int mask;
#define ACPI_LPI_COORDINATED 3
#define ACPI_LPI_DIRECT 1
#define GFP_KERNEL 0
#define CPUHP_INVALID -1
#define WRITE_ONCE(x,v) ((x)=(v))
#define lockdep_assert_held(x) ((void)(x))
static int acpi_lpi_lifecycle=3,acpi_lpi_lifecycle_lock,acpi_lpi_cpuhp_state=4,acpi_idle_syscore,acpi_idle_pm_notifier,acpi_lpi_syscore_suspended_cpus;
static bool acpi_lpi_syscore_suspending,acpi_lpi_system_sleep;
static int mode_ret=-EACCES,tables,hooks_removed,cpuidle_enabled,lockdepth;
#define alloc_cpumask_var(p,g) (*(p)=&mask,true)
static void free_cpumask_var(int *x){(void)x;}
static void cpus_read_lock(void){lockdepth++;}static void cpus_read_unlock(void){lockdepth--;}
static void cpuidle_pause_and_lock(void){}static void cpuidle_resume_and_unlock(void){}
static void acpi_lpi_disable_cpuidle_devices(int*x){*x=1;}
static int acpi_processor_ffh_lpi_set_mode(bool b){assert(!b);return mode_ret;}
static int acpi_lpi_enable_cpuidle_devices(int*x){(void)x;cpuidle_enabled++;return 0;}
static void acpi_lpi_setup_cpuidle_states(bool b){assert(!b);tables++;}
static void cpuhp_remove_state_nocalls_cpuslocked(int x){(void)x;hooks_removed++;}
static void unregister_syscore(int*x){(void)x;hooks_removed++;}
static void unregister_pm_notifier(int*x){(void)x;hooks_removed++;}
static void cpumask_clear(int*x){*x=0;}
#define pr_info(...) ((void)0)
'''
main=r'''
int main(void){assert(acpi_lpi_deactivate_locked()==-EACCES);assert(acpi_lpi_lifecycle==3&&!tables&&!hooks_removed&&cpuidle_enabled==1&&!lockdepth);mode_ret=0;assert(!acpi_lpi_deactivate_locked());assert(acpi_lpi_lifecycle==1&&tables==1&&hooks_removed==3&&!lockdepth);puts("PASS actual mode rollback: DENIED retains coordinated lifecycle/hooks/guards; success unpublishes after PC transition");return 0;}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'t.c').write_text(prefix+s[a:i]+main);subprocess.run(['cc','-std=gnu11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'t.c'),'-o',str(p/'t')],check=True);subprocess.run([str(p/'t')],check=True)
