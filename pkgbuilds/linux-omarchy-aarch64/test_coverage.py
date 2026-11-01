#!/usr/bin/env python3
"""Gate the actual private coverage predicate before global mode publication."""
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
s=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text()
a=s.index('\tif (n1x_coordinated_requested) {',s.index('static int acpi_lpi_activate_locked'))
b=s.index('\tret = acpi_lpi_sync_runtime_pm',a)
block=s[a:b].replace('goto remove_cpuhp;','goto refused;')
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
static int gate(void){int ret=0;
'''+block+r'''
osi_calls++;return 0;refused:return ret;}
int main(void){for(int i=0;i<20;i++)records[i]=(struct acpi_idle_data){true,4,7};assert(!gate()&&osi_calls==1);for(int i=0;i<20;i++){records[i].n1x_levels=3;assert(gate()==-EINVAL&&osi_calls==1);records[i].n1x_levels=4;records[i].n1x_compositions=6;assert(gate()==-EINVAL&&osi_calls==1);records[i].n1x_compositions=7;records[i].n1x_private=false;assert(gate()==-EINVAL&&osi_calls==1);records[i].n1x_private=true;}present=19;assert(gate()==-EINVAL&&osi_calls==1);present=20;firmware=false;assert(gate()==-EINVAL&&osi_calls==1);puts("PASS actual pre-mode coverage: all20CPU3parents7composition/privatefirmware gate before any OSI publication");return 0;}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'t.c').write_text(code);subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'t.c'),'-o',str(p/'t')],check=True);subprocess.run([str(p/'t')],check=True)
