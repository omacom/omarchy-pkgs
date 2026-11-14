"""Compile actual ASUS registration and fan detection functions under capability variants."""
from pathlib import Path
import argparse, re, subprocess, tempfile

def function(text,name):
 m=re.search(r'^static [^\n]+\b'+name+r'\([^;]*?\)\n\{',text,re.M)
 if not m:raise ValueError(name)
 i=m.end();depth=1
 while depth:
  depth+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[m.start():i]

def run(code,defines):
 with tempfile.TemporaryDirectory() as d:
  p=Path(d);(p/'test.c').write_text(code)
  subprocess.run(['cc','-std=gnu11','-Werror','-Wall','-Wextra','-Wno-unused-function',*defines,str(p/'test.c'),'-o',str(p/'test')],check=True)
  subprocess.run([str(p/'test')],check=True)

def main():
 a=argparse.ArgumentParser();a.add_argument('source',type=Path);args=a.parse_args()
 t=(args.source/'drivers/platform/x86/asus-wmi.c').read_text()
 start=t.index('#if defined(CONFIG_SUSPEND)\nstatic void asus_ally_s2idle_restore') if '#if defined(CONFIG_SUSPEND)\nstatic void asus_ally_s2idle_restore' in t else t.index('#if defined(CONFIG_SUSPEND) && defined(CONFIG_X86)\nstatic void asus_ally_s2idle_restore')
 end=t.index('#endif /* CONFIG_SUSPEND',start);end=t.index('\n',end)
 block=t[start:end]
 pre='''
#include <assert.h>
#include <stddef.h>
#include <errno.h>
#define ASUS_WMI_ALLY_MCU_HACK_ENABLED 1
#define ASUS_USB0_PWR_EC0_CSEE "CSEE"
#define ASUS_USB0_PWR_EC0_CSEE_ON 0xB8
#define ASUS_USB0_PWR_EC0_CSEE_WAIT 600
static int use_ally_mcu_hack, registrations, removals, warnings;
struct acpi_s2idle_dev_ops { void (*restore)(void); };
static void acpi_execute_simple_method(void *p,const char *n,int v) {(void)p;(void)n;(void)v;}
static void msleep(int v) {(void)v;}
static void pr_warn(const char *s) {(void)s;warnings++;}
static int acpi_register_lps0_dev(struct acpi_s2idle_dev_ops *p) {(void)p;registrations++;
#ifdef CONFIG_X86
return 0;
#else
return -ENODEV;
#endif
}
static void acpi_unregister_lps0_dev(struct acpi_s2idle_dev_ops *p) {(void)p;removals++;}
'''
 tail='''
int main(void) { (void)use_ally_mcu_hack; asus_s2idle_check_register(); asus_s2idle_check_unregister();
#if defined(CONFIG_SUSPEND) && defined(CONFIG_X86)
assert(registrations==1 && removals==1);
#else
assert(registrations==0 && removals==0);
#endif
assert(warnings==0);return 0;}
'''
 for defines in [[],['-DCONFIG_SUSPEND'],['-DCONFIG_SUSPEND','-DCONFIG_X86']]:run(pre+block+tail,defines)
 fan='''
#include <assert.h>
#include <stdbool.h>
typedef unsigned int u32;
#define FAN_TYPE_NONE 0
#define ASUS_WMI_DEVID_CPU_FAN_CURVE 0x24
#define ASUS_WMI_DEVID_GPU_FAN_CURVE 0x25
#define ASUS_WMI_DEVID_MID_FAN_CURVE 0x32
struct asus_wmi { int fan_type,gpu_fan_type,mid_fan_type; };
static int calls;
static int fan_curve_get_factory_default(struct asus_wmi *a,unsigned int dev) {(void)a;(void)dev;calls++;return 0;}
'''+function(t,'fan_curve_check_present')+'''
int main(void) {struct asus_wmi a={1,1,0}; bool available=true;
fan_curve_check_present(&a,&available,ASUS_WMI_DEVID_MID_FAN_CURVE);assert(!available && calls==0);
fan_curve_check_present(&a,&available,ASUS_WMI_DEVID_CPU_FAN_CURVE);assert(available && calls==1);
fan_curve_check_present(&a,&available,ASUS_WMI_DEVID_GPU_FAN_CURVE);assert(available && calls==2);
a.mid_fan_type=1;fan_curve_check_present(&a,&available,ASUS_WMI_DEVID_MID_FAN_CURVE);assert(available && calls==3);
a.fan_type=0;fan_curve_check_present(&a,&available,ASUS_WMI_DEVID_GPU_FAN_CURVE);assert(available && calls==4);return 0;}
'''
 run(fan,[])
 # Test the actual filter install/remove conditions without copying policy.
 install=re.search(r'if \(.*asus->driver->i8042_filter\) \{\n\s*err = i8042_install_filter',t)[0].split(' {')[0]
 remove=re.search(r'if \(.*asus->driver->i8042_filter\)\n\s*i8042_remove_filter',t)[0].split('\n')[0]
 for reachable in (0,1):
  code=f"""
#include <assert.h>
#define IS_REACHABLE(x) {reachable}
struct driver {{ int i8042_filter; }};
struct state {{ struct driver *driver; }};
int main(void) {{ struct driver d={{1}}; struct state a={{&d}}, *asus=&a;
int installs=0,removes=0; {install} installs++; {remove} removes++;
assert(installs=={reachable} && removes=={reachable}); return 0; }}
"""
  run(code,[])
 print('PASS ASUS LPS0 architecture variants, i8042 reachability and per-fan capability checks')
if __name__=='__main__':main()
