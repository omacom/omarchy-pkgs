#!/usr/bin/env python3
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
s=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text()
def extract(name):
 m=re.search(r'static (?:int|bool)(?: __cpuidle)?\s+'+name+r'\([^;]+?\)\n\{',s)
 assert m,name
 a,i,d=m.start(),m.end(),1
 while d:
  if s[i]=='{':d+=1
  elif s[i]=='}':d-=1
  i+=1
 return s[a:i]
prefix=r'''
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#define __cpuidle
#define READ_ONCE(x) (x)
#define unlikely(x) (x)
#define WARN_ON_ONCE(x) (x)
#define IS_ENABLED(x) 0
#define CONFIG_PREEMPT_RT 0
#define ACPI_CSTATE_FFH 1
#define CPUIDLE_FLAG_RCU_IDLE 1
struct acpi_lpi_state { int entry_method; };
struct cpuidle_device { int unused; };
struct cpuidle_driver { struct {int flags;} states[2]; };
struct generic_pm_domain { int unused; };
struct acpi_lpi_genpd_map_entry {struct generic_pm_domain *genpd;};
struct acpi_lpi_runtime_state {struct generic_pm_domain *genpd;struct acpi_lpi_state state;};
struct acpi_idle_data {void *domain_dev;bool n1x_private,consumer_active,genpd_suspended;struct acpi_lpi_genpd_map_entry *base_map_entry;struct acpi_lpi_runtime_state *domain_state;};
struct acpi_processor {struct {struct acpi_lpi_state lpi_states[2];} power;};
static struct acpi_processor processor,*processors=&processor;
static struct acpi_idle_data data,*acpi_idle_data=&data;
#define __this_cpu_read(x) (x)
#define this_cpu_read(x) (x)
static bool acpi_lpi_rebuild_pending,acpi_lpi_system_sleep,sleeping,shared=true;
static int leaf_calls,puts,gets,suspends,resumes,fw_calls,rejects,fail;
static struct generic_pm_domain leafpd,parentpd;
static struct acpi_lpi_runtime_state selected;
static int acpi_idle_lpi_enter_leaf(struct cpuidle_device*d,struct cpuidle_driver*r,int i){(void)d;(void)r;leaf_calls++;return i;}
static bool idle_should_enter_s2idle(void){return sleeping;}
static bool pm_suspend_in_progress(void){return false;}
static void acpi_lpi_clear_selected_states(struct acpi_idle_data*d){d->domain_state=0;}
static void dev_pm_genpd_suspend_s2idle(void*dev){(void)dev;suspends++;selected.genpd=shared?&parentpd:&leafpd;selected.state.entry_method=1;data.domain_state=&selected;}
static int pm_runtime_put_sync_suspend(void*dev){(void)dev;puts++;return 0;}
static void pm_runtime_get_noresume(void*dev){(void)dev;gets++;}
static void acpi_lpi_prepare_ffh_entry_state(struct acpi_lpi_state*l,struct acpi_lpi_state*s){*l=*s;}
static bool acpi_lpi_leaf_domain_disabled(struct acpi_idle_data*d){(void)d;return false;}
static int acpi_processor_ffh_lpi_prepare_state(struct acpi_lpi_state*l){(void)l;return 0;}
static int acpi_processor_ffh_lpi_enter(struct acpi_lpi_state*l){(void)l;fw_calls++;return fail?-5:0;}
static void ct_cpuidle_enter(void){}
static void ct_cpuidle_exit(void){}
static void acpi_lpi_reject_selected_states(struct acpi_idle_data*d,bool s){(void)d;(void)s;rejects++;}
static void dev_pm_genpd_resume(void*dev){(void)dev;resumes++;}
static int pm_runtime_resume_and_get(void*dev){(void)dev;gets++;return 0;}
'''
main=r'''
int main(void){struct cpuidle_device d;struct cpuidle_driver drv={0};struct acpi_lpi_genpd_map_entry base={&leafpd};data.domain_dev=&d;data.base_map_entry=&base;data.n1x_private=true;data.consumer_active=true;
assert(__acpi_idle_lpi_enter_domain(&d,&drv,1,false)==1);assert(leaf_calls==1&&!puts&&!gets&&!suspends&&!fw_calls);
assert(__acpi_idle_lpi_enter_domain(&d,&drv,1,true)==-EBUSY);assert(!suspends);
sleeping=true;assert(__acpi_idle_lpi_enter_domain(&d,&drv,1,true)==1);assert(suspends==1&&resumes==1&&fw_calls==1&&!data.domain_state);
fail=1;assert(__acpi_idle_lpi_enter_domain(&d,&drv,1,true)==-5);assert(suspends==2&&resumes==2&&rejects==1&&!data.domain_state);
assert(!puts&&!gets);puts("PASS actual coordinated entry: ordinary leaf keeps refs, real s2idle success/error balanced, stale-state cleared");return 0;}
'''
# Avoid libc puts symbol collision with mock counter.
prefix=prefix.replace('puts,gets,','put_count,get_count,').replace('puts++;','put_count++;').replace('gets++;','get_count++;')
main=main.replace('!puts','!put_count').replace('!gets','!get_count')
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'t.c').write_text(prefix+extract('__acpi_idle_lpi_enter_domain')+main)
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'t.c'),'-o',str(p/'t')],check=True);subprocess.run([str(p/'t')],check=True)
