#!/usr/bin/env python3
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
s=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text();m=re.search(r'static int __cpuidle\s+acpi_idle_lpi_enter_leaf\([^;]+?\)\n\{',s);a,i,d=m.start(),m.end(),1
while d:
 if s[i]=='{':d+=1
 elif s[i]=='}':d-=1
 i+=1
code=r'''
#include <stdbool.h>
#include <assert.h>
#include <stdio.h>
#include <errno.h>
#define __cpuidle
#define unlikely(x) (x)
#define ACPI_CSTATE_FFH 1
struct acpi_lpi_state{int entry_method;};
struct acpi_processor{struct{struct acpi_lpi_state lpi_states[2];}power;};
struct acpi_idle_data{int unused;};struct cpuidle_device{int unused;};struct cpuidle_driver{int unused;};
static struct acpi_processor pr,*processors=&pr;static struct acpi_idle_data d,*acpi_idle_data=&d;
#define __this_cpu_read(x) (x)
#define this_cpu_read(x) (x)
static bool n1x_coordinated_requested=true,disabled;static int entered,exited,direct,prepared,firmware;
static bool acpi_lpi_leaf_domain_disabled(struct acpi_idle_data*p){return p&&disabled;}
static void ct_cpuidle_enter(void){entered++;}static void ct_cpuidle_exit(void){exited++;}
static int acpi_idle_lpi_enter_direct(struct cpuidle_device*p,struct cpuidle_driver*q,int i){(void)p;(void)q;direct++;return i;}
static int acpi_processor_ffh_lpi_prepare_state(struct acpi_lpi_state*l){(void)l;prepared++;return 0;}
static int acpi_processor_ffh_lpi_enter(struct acpi_lpi_state*l){(void)l;firmware++;return 0;}
'''+s[a:i]+r'''
int main(void){struct cpuidle_device p;struct cpuidle_driver q;pr.power.lpi_states[1].entry_method=1;disabled=true;assert(!acpi_idle_lpi_enter_leaf(&p,&q,1));assert(entered==1&&exited==1&&direct==1&&!prepared&&!firmware);disabled=false;assert(acpi_idle_lpi_enter_leaf(&p,&q,1)==1);assert(prepared==1&&firmware==1);processors=0;assert(acpi_idle_lpi_enter_leaf(&p,&q,1)==-EINVAL);processors=&pr;acpi_idle_data=0;assert(acpi_idle_lpi_enter_leaf(&p,&q,1)==1);puts("PASS actual leaf disabled->WFI RCU pair, enabled prepared leaf, null processor/data");return 0;}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'t.c').write_text(code);subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'t.c'),'-o',str(p/'t')],check=True);subprocess.run([str(p/'t')],check=True)
