#!/usr/bin/env python3
"""Gate the tested private hierarchy; other N1x SKUs keep the normal fallback."""
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
source_text=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text()
patch_text=(Path(__file__).resolve().parent/'1122-n1x-coordinated-suspend-only.patch').read_text()
s=source_text
permanent_gate='''\t\tif (!n1x_coordinated_allowed() || num_present_cpus() != 20) {
\t\t\tret = -EOPNOTSUPP;'''
assert s.count(permanent_gate)==1, 'prepared source must contain permanent platform/count rejection'
assert '+'+permanent_gate.replace('\n','\n+') in patch_text
a=s.index('\tif (n1x_coordinated_requested) {',s.index('static int acpi_lpi_activate_locked'))
b=s.index('\tret = acpi_lpi_sync_runtime_pm',a)
block=s[a:b].replace('goto remove_cpuhp;','goto refused;')
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
 for(int i=0;i<20;i++)records[i]=(struct acpi_idle_data){true,4,7};
 assert(!gate()&&osi_calls==1);
 for(int i=0;i<20;i++){
  records[i].n1x_levels=3;
  assert(gate()==-EINVAL&&acpi_lpi_retryable_error(-EINVAL)&&osi_calls==1);
  records[i].n1x_levels=4;records[i].n1x_compositions=6;
  assert(gate()==-EINVAL&&acpi_lpi_retryable_error(-EINVAL)&&osi_calls==1);
  records[i].n1x_compositions=7;records[i].n1x_private=false;
  assert(gate()==-EINVAL&&acpi_lpi_retryable_error(-EINVAL)&&osi_calls==1);
  records[i].n1x_private=true;
 }
 /* An 18-CPU N1x SKU is real hardware, not a transient incomplete probe.
  * The current firmware policy is tested only for the 20-CPU P16; a count
  * reduction (including nr_cpus=18 on that P16) must not cause rebuild loops. */
 const int unvalidated_counts[]={16,18,19};
 for(unsigned int i=0;i<sizeof(unvalidated_counts)/sizeof(unvalidated_counts[0]);i++){
  present=unvalidated_counts[i];
  assert(gate()==-EOPNOTSUPP&&osi_calls==1);
  assert(!acpi_lpi_retryable_error(-EOPNOTSUPP));
 }
 present=20;firmware=false;
 assert(gate()==-EOPNOTSUPP&&osi_calls==1);
 assert(!acpi_lpi_retryable_error(-EOPNOTSUPP));
 assert(acpi_lpi_retryable_error(-EINVAL));
 assert(acpi_lpi_retryable_error(-ENOMEM));
 assert(!acpi_lpi_retryable_error(-ENODEV));
 puts("PASS actual pre-mode coverage: 16/18/19 CPU fallback stops retries; validated 20-CPU hierarchy and transient per-CPU retries preserved");
 return 0;
}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'t.c').write_text(code);subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'t.c'),'-o',str(p/'t')],check=True);subprocess.run([str(p/'t')],check=True)
