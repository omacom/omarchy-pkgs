#!/usr/bin/env python3
"""Compile actual private admission and shared-domain/entry functions in mocks."""
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re,subprocess,tempfile
SRC=KERNEL_SOURCE/'drivers/acpi/processor_idle.c'
s=SRC.read_text()
def function(name):
 m=re.search(r'(?:static (?:int|bool)(?: __cpuidle)?\s+|static int __cpuidle\n)'+name+r'\([^;]+?\)\n\{',s)
 if not m: raise ValueError(name)
 a,i,d=m.start(),m.end(),1
 while d:
  if s[i]=='{':d+=1
  elif s[i]=='}':d-=1
  i+=1
 return s[a:i]
preamble=r'''
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
typedef uint32_t u32;typedef uint64_t u64;typedef const char *acpi_handle;
#define ACPI_CSTATE_FFH 1
#define ACPI_CSTATE_INTEGER 2
#define ACPI_LPI_STATE_FLAGS_ENABLED 1
#define ACPI_ALLOCATE_BUFFER 0
#define ACPI_FULL_PATHNAME 0
#define ACPI_FAILURE(x) (x)
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define kfree free
struct acpi_buffer{size_t length;void*pointer;};
static int acpi_get_name(acpi_handle h,int type,struct acpi_buffer*b){(void)type;b->pointer=strdup(h);return !b->pointer;}
struct acpi_lpi_state{u64 address,level_id;u32 min_residency,wake_latency,flags,arch_flags,res_cnt_freq,enable_parent_state,index;unsigned int entry_method,bit_width,bit_offset,access_size;char desc[64];};
'''
a=s.index('struct n1x_lpi_array');b=s.index('struct acpi_lpi_pd_init_data',a)
tuples=s[a:b]
header=(KERNEL_SOURCE/'include/acpi/processor.h').read_text()
a=header.index('static inline bool\nacpi_processor_combine_lpi_states');b=header.index('\nstruct ',a)
combine=header[a:b]
extra=r'''
#define GFP_KERNEL 0
#define kmemdup_array(p,n,z,g) memcpy(malloc((n)*(z)),p,(n)*(z))
#define check_add_overflow(a,b,p) __builtin_add_overflow(a,b,p)
#define U32_MAX UINT32_MAX
#include <stdarg.h>
static int scnprintf(char *dst,size_t n,const char *fmt,...){va_list ap;va_start(ap,fmt);int r=vsnprintf(dst,n,fmt,ap);va_end(ap);return r;}
#define ACPI_CX_DESC_LEN 64
struct mock_pd {int (*power_off)(void*);};
struct mock_map {bool s2idle_only;struct mock_pd *genpd;};
static struct mock_pd pd;
static int acpi_lpi_pd_power_off_s2idle(void *p){(void)p;return 0;}
struct acpi_lpi_pd_init_data {bool n1x_private;unsigned int n1x_levels,n1x_count,n1x_prev_count;struct acpi_lpi_state n1x_prev[2];struct mock_map *child_map_entry;};
static struct mock_map map;
static int level_calls,prepare_fail;
static bool acpi_processor_ffh_lpi_is_wfi(struct acpi_lpi_state*l){return l->entry_method==1&&l->address==0xffffffff;}
static int acpi_processor_ffh_lpi_prepare_state(struct acpi_lpi_state*l){(void)l;return prepare_fail?-EINVAL:0;}
static int acpi_lpi_pd_init_level(acpi_handle h,const struct acpi_lpi_state*l,unsigned int c,unsigned int v,void*a){(void)h;(void)l;(void)c;(void)v;level_calls++;map.genpd=&pd;((struct acpi_lpi_pd_init_data*)a)->child_map_entry=&map;return 0;}
'''
callback=function('acpi_lpi_pd_init_cb')
main=r'''
static struct acpi_lpi_state make(const char*d,u64 addr,u32 r,u32 l,u32 p,u32 i,u64 level){struct acpi_lpi_state x={.address=addr,.level_id=level,.min_residency=r,.wake_latency=l,.enable_parent_state=p,.index=i,.arch_flags=1,.res_cnt_freq=1000000000,.entry_method=1,.bit_width=32,.access_size=3};snprintf(x.desc,64,"%s",d);return x;}
int main(void){struct acpi_lpi_state raw[2],saved[2];struct n1x_lpi_array a={raw,2};
raw[0]=make("PlatIdle-PGKSL",0x01010012,2635,0,1,1,0x1000);raw[1]=make("PlatIdle-PGKLL",0x01010013,1490,393,1,2,0x1000);memcpy(saved,raw,sizeof raw);
assert(n1x_admit_parent_lpis("\\_SB_.SYSM.PKG0",&a,1));assert(raw[0].flags==1&&raw[1].flags==1);
for(int bad=0;bad<10;bad++){memcpy(raw,saved,sizeof raw);switch(bad){case 0:raw[1].flags=1;break;case 1:raw[1].address++;break;case 2:raw[1].wake_latency++;break;case 3:raw[1].level_id++;break;case 4:raw[1].bit_width=64;break;case 5:raw[1].bit_offset=1;break;case 6:raw[1].access_size=0;break;case 7:raw[1].index++;break;case 8:raw[1].res_cnt_freq++;break;case 9:raw[1].enable_parent_state++;break;}assert(!n1x_admit_parent_lpis("\\_SB_.SYSM.PKG0",&a,1));assert(!raw[0].flags);}
memcpy(raw,saved,sizeof raw);assert(!n1x_admit_parent_lpis("\\_SB_.OTHER",&a,1));assert(!n1x_admit_parent_lpis("\\_SB_.SYSM.PKG0",&a,2));assert(!memcmp(raw,saved,sizeof raw));
struct acpi_lpi_pd_init_data init={.n1x_private=true};
struct acpi_lpi_state leaf[2];
leaf[0]=make("CoreIdle-WFI",0xffffffff,0,0,0,1,0);leaf[0].arch_flags=0;leaf[0].flags=1;
leaf[1]=make("CoreIdle-OFF",0x10000,2006,170,1,2,0);leaf[1].flags=1;
assert(!acpi_lpi_pd_init_cb("leaf",leaf,2,0,&init));assert(init.n1x_levels==1&&init.n1x_count==2);
raw[0]=make("PlatIdle-DSUOFF",0x01010011,2635,404,2,1,0x1000);a.size=1;
assert(!acpi_lpi_pd_init_cb("\\_SB_.SYSM.PKG0.CLU0",raw,1,1,&init));assert(!raw[0].flags&&map.s2idle_only);
raw[0]=saved[0];raw[1]=saved[1];assert(!acpi_lpi_pd_init_cb("\\_SB_.SYSM.PKG0",raw,2,2,&init));
raw[0]=make("Standby-DRIPS",0x020100f0,1437,6610,0,1,0x2000);
assert(!acpi_lpi_pd_init_cb("\\_SB_.SYSM",raw,1,3,&init));assert(init.n1x_levels==4&&init.n1x_count==7);
assert(level_calls==4);assert(acpi_lpi_pd_init_cb("extra",raw,1,4,&init)==-EINVAL);
struct acpi_lpi_pd_init_data badinit={.n1x_private=true};leaf[1].wake_latency++;
assert(acpi_lpi_pd_init_cb("leaf",leaf,2,0,&badinit)==-EINVAL);assert(!badinit.n1x_levels&&!badinit.n1x_count);
puts("PASS actual exact tuple atomic admission and private hierarchy 4levels/7compositions; rawflags unchanged; partial/shape reject");return 0;}
'''
with tempfile.TemporaryDirectory() as t:
 p=Path(t);(p/'test.c').write_text(preamble+tuples+extra+combine+callback+main)
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(p/'test.c'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
