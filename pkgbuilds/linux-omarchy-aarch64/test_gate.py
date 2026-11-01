#!/usr/bin/env python3
"""Exercise the actual opt-in/firmware gate without ACPI evaluation or hardware."""
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import re
import subprocess
import tempfile
source=(KERNEL_SOURCE/'drivers/acpi/processor_idle.c').read_text()
def function(name):
 m=re.search(r'^.*\b'+name+r'\([^;]*?\n\{',source,re.M);assert m,name
 start=m.start();i=source.index('{',m.start())+1;depth=1
 while depth:
  if source[i]=='{':depth+=1
  elif source[i]=='}':depth-=1
  i+=1
 return source[start:i]
prefix=r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define SHA256_DIGEST_SIZE 32
#define __init
#define DMI_SYS_VENDOR 1
#define DMI_PRODUCT_NAME 2
#define DMI_BIOS_VERSION 3
#define ACPI_SIG_DSDT "DSDT"
#define ACPI_FAILURE(x) ((x)!=0)
#define pr_info(...) do {} while(0)
#define mutex_lock(x) ((void)(x))
#define mutex_unlock(x) ((void)(x))
typedef uint8_t u8;
struct acpi_table_header{unsigned int length;};
static bool n1x_coordinated_requested,n1x_coordinated_gate_checked,n1x_coordinated_gate_allowed;
static int n1x_coordinated_gate_lock;
static bool good_vendor=true,good_model=true,good_bios=true,pep=true,good_hash=true,table_present=true;
static int gets,puts_count,hashes;
static struct acpi_table_header table={.length=73551};
static int dmi_match(int field,const char *expected){(void)expected;return field==1?good_vendor:field==2?good_model:good_bios;}
static int acpi_dev_present(const char *hid,const char *uid,int rev){(void)hid;(void)uid;(void)rev;return pep;}
static int acpi_get_table(const char *signature,int instance,struct acpi_table_header **out){(void)signature;(void)instance;gets++;*out=&table;return table_present?0:1;}
static void acpi_put_table(struct acpi_table_header *out){assert(out==&table);puts_count++;}
static void sha256(const u8 *data,size_t len,u8 *out){
 static const u8 digest[32]={0x5e,0xce,0xd7,0x5d,0x1b,0x24,0xc7,0xfb,0xd0,0x69,0xaa,0x92,0x40,0x69,0x51,0x47,0x84,0x8b,0xbf,0xca,0x56,0xcc,0xe7,0x6a,0xb7,0xf4,0xa6,0xa0,0xeb,0xa9,0x84,0x9f};
 assert(data==(const u8 *)&table && len==73551);hashes++;memcpy(out,digest,32);if(!good_hash)out[0]^=1;
}
static void reset(void){n1x_coordinated_requested=false;n1x_coordinated_gate_checked=false;n1x_coordinated_gate_allowed=false;good_vendor=good_model=good_bios=pep=good_hash=table_present=true;table.length=73551;gets=puts_count=hashes=0;}
'''
main=r'''
int main(void){
 reset();n1x_coordinated_setup(NULL);assert(!n1x_coordinated_allowed() && gets==0);
 reset();n1x_coordinated_setup("0");assert(!n1x_coordinated_allowed() && gets==0);
 reset();n1x_coordinated_setup("true");assert(!n1x_coordinated_allowed() && gets==0);
 reset();n1x_coordinated_setup("1");assert(n1x_coordinated_allowed() && gets==1 && puts_count==1 && hashes==1);assert(n1x_coordinated_allowed() && gets==1);
 for(int bad=0;bad<7;bad++){
  reset();n1x_coordinated_setup("1");
  if(bad==0)good_vendor=false;if(bad==1)good_model=false;if(bad==2)good_bios=false;if(bad==3)pep=false;if(bad==4)good_hash=false;if(bad==5)table_present=false;if(bad==6)table.length++;
  assert(!n1x_coordinated_allowed());if(bad<4)assert(gets==0);if(bad==4)assert(hashes==1 && puts_count==1);if(bad==5)assert(puts_count==0);if(bad==6)assert(hashes==0 && puts_count==1);
 }
 puts("PASS actual firmware gate: explicit opt-in, DMI/model/BIOS/PEP/hash/table length and cache/refcount negative paths");return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='n1x-lpi-gate-') as td:
 c=Path(td)/'gate.c';exe=Path(td)/'test';c.write_text(prefix+'\n'+function('n1x_coordinated_setup')+'\n'+function('n1x_coordinated_allowed')+'\n'+main)
 subprocess.run(['cc','-std=gnu11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-fsanitize=address,undefined','-g',str(c),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
