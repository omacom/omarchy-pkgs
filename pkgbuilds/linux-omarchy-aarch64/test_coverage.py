#!/usr/bin/env python3
"""Gate 18/20-CPU private hierarchies before global mode publication."""
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
source_text=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text()
patch_text=(Path(__file__).resolve().parent/'1122-n1x-coordinated-suspend-only.patch').read_text()
s=source_text
a=s.index('\tif (n1x_coordinated_requested) {',s.index('static int acpi_lpi_activate_locked'))
b=s.index('\tret = acpi_lpi_sync_runtime_pm',a)
block=s[a:b]
assert '\t\t\tret = -EOPNOTSUPP;' in block, 'permanent admission must not retry'
assert all('+'+line in patch_text for line in block.splitlines())
assert s.index('if (!acpi_lpi_complete_cpu_coverage())',s.index('static int acpi_lpi_activate_locked')) < a
assert 'admission: %u CPUs, 3 parent levels, 7 compositions;' in patch_text
assert re.search(r'admission: %u CPUs[^\n]*\n\+\s*num_present_cpus\(\)\);',patch_text)
block=block.replace('goto remove_cpuhp;','goto refused;')
retry=s[s.index('static bool acpi_lpi_retryable_error('):]
retry=retry[:retry.index('\n}')+2]
code=r'''
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <stdio.h>
struct acpi_idle_data {bool n1x_private;unsigned int n1x_levels,n1x_compositions;};
static struct acpi_idle_data records[20];static int present=20,osi_calls;static bool n1x_coordinated_requested=true,firmware=true;
#define per_cpu(x,cpu) (&records[cpu])
#define for_each_present_cpu(cpu) for(cpu=0;cpu<present;cpu++)
static int num_present_cpus(void){return present;}
static bool n1x_coordinated_allowed(void){return firmware;}
'''+retry+r'''
static int gate(void){int ret=0;
'''+block+r'''
osi_calls++;return 0;refused:return ret;}
int main(void){
 const int admitted_counts[]={18,20};
 for(unsigned int n=0;n<sizeof(admitted_counts)/sizeof(admitted_counts[0]);n++){
  present=admitted_counts[n];
  for(int i=0;i<20;i++)records[i]=(struct acpi_idle_data){true,4,7};
  int before=osi_calls;
  assert(!gate()&&osi_calls==before+1);
  for(int i=0;i<present;i++){
   records[i].n1x_levels=3;
   assert(gate()==-EINVAL&&acpi_lpi_retryable_error(-EINVAL)&&osi_calls==before+1);
   records[i].n1x_levels=4;records[i].n1x_compositions=6;
   assert(gate()==-EINVAL&&acpi_lpi_retryable_error(-EINVAL)&&osi_calls==before+1);
   records[i].n1x_compositions=7;records[i].n1x_private=false;
   assert(gate()==-EINVAL&&acpi_lpi_retryable_error(-EINVAL)&&osi_calls==before+1);
   records[i].n1x_private=true;
  }
 }
 const int unvalidated_counts[]={16,19};
 for(unsigned int i=0;i<sizeof(unvalidated_counts)/sizeof(unvalidated_counts[0]);i++){
  present=unvalidated_counts[i];
  assert(gate()==-EOPNOTSUPP&&osi_calls==2);
  assert(!acpi_lpi_retryable_error(-EOPNOTSUPP));
 }
 present=20;firmware=false;
 assert(gate()==-EOPNOTSUPP&&osi_calls==2);
 assert(!acpi_lpi_retryable_error(-EOPNOTSUPP));
 assert(acpi_lpi_retryable_error(-EINVAL));
 assert(acpi_lpi_retryable_error(-ENOMEM));
 assert(!acpi_lpi_retryable_error(-ENODEV));
 puts("PASS actual pre-mode coverage: 18/20 CPU admission, every CPU's private hierarchy required; 16/19 permanent fallback and transient retries preserved");
 return 0;
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'t.c').write_text(code);subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'t.c'),'-o',str(p/'t')],check=True);subprocess.run([str(p/'t')],check=True)

# A supported present count alone must never bypass complete present-CPU
# coverage. Possible/offline CPU slots are not members of this admission mask.
start=s.index('static bool acpi_lpi_complete_cpu_coverage(')
end=s.index('\n}',start)+2
coverage=s[start:end]
code=r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#define CPUIDLE_STATE_MAX 16
struct acpi_lpi_state { bool wfi; };
struct acpi_processor {
 struct { bool power_setup_done, has_lpi; } flags;
 struct { unsigned int count; struct acpi_lpi_state lpi_states[2]; } power;
};
struct power_domain { unsigned int state_count; };
struct acpi_lpi_genpd_map_entry { struct power_domain *genpd; };
struct acpi_idle_data {
 void *domain_dev;
 struct acpi_lpi_genpd_map_entry *base_map_entry;
 unsigned int leaf_lpi_count;
};
static struct acpi_processor processors[20];
static struct acpi_idle_data acpi_idle_data[20];
static struct power_domain domains[20];
static struct acpi_lpi_genpd_map_entry entries[20];
static bool excluded[20],registered[20];
static int present;
#define acpi_lpi_excluded_cpus excluded
#define cpumask_test_cpu(cpu,mask) ((void)(mask),excluded[cpu])
#define per_cpu(array,cpu) (&array[cpu])
#define for_each_present_cpu(cpu) for(cpu=0;cpu<present;cpu++)
static bool acpi_idle_driver_is_registered(int cpu){return registered[cpu];}
static bool acpi_processor_ffh_lpi_is_wfi(struct acpi_lpi_state *s){return s->wfi;}
'''+coverage+r'''
int main(void){
 for(int n=18;n<=20;n+=2){
  present=n;
  for(int i=0;i<20;i++){
   processors[i]=(struct acpi_processor){{true,true},{2,{{true},{false}}}};
   domains[i].state_count=1;entries[i].genpd=&domains[i];
   acpi_idle_data[i]=(struct acpi_idle_data){&domains[i],&entries[i],2};
   registered[i]=true;excluded[i]=false;
  }
  assert(acpi_lpi_complete_cpu_coverage());
  for(int i=0;i<present;i++){
   excluded[i]=true;assert(!acpi_lpi_complete_cpu_coverage());excluded[i]=false;
   registered[i]=false;assert(!acpi_lpi_complete_cpu_coverage());registered[i]=true;
   acpi_idle_data[i].domain_dev=NULL;assert(!acpi_lpi_complete_cpu_coverage());acpi_idle_data[i].domain_dev=&domains[i];
   processors[i].flags.has_lpi=false;assert(!acpi_lpi_complete_cpu_coverage());processors[i].flags.has_lpi=true;
  }
  /* Possible CPUs outside an 18-CPU present mask must not be read. */
  if(present==18){registered[18]=registered[19]=false;assert(acpi_lpi_complete_cpu_coverage());}
 }
 present=0;assert(!acpi_lpi_complete_cpu_coverage());
 puts("PASS actual present-CPU coverage: 18/20 complete masks pass, excluded/missing present CPUs reject, absent slots ignored");
 return 0;
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'coverage.c').write_text(code)
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'coverage.c'),'-o',str(p/'coverage')],check=True)
 subprocess.run([str(p/'coverage')],check=True)
