#!/usr/bin/env python3
"""Exercise the actual opt-in/firmware gate without ACPI evaluation or hardware."""
from pathlib import Path
import re
import sys
import subprocess
import tempfile
ROOT=Path(sys.argv[1]).resolve()
source=(ROOT/'drivers/acpi/processor_idle.c').read_text()
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
#include <stdio.h>
#include <string.h>
#define IS_BUILTIN(x) ((x) == 1)
#define CONFIG_ACPI_PROCESSOR 1
#define __init
#define DMI_SYS_VENDOR 1
#define DMI_PRODUCT_NAME 2
#define pr_info(...) do {} while (0)
#define pr_warn(...) do {} while (0)
#define mutex_lock(x) ((void)(x))
#define mutex_unlock(x) ((void)(x))
static bool n1x_coordinated_requested,n1x_coordinated_disabled;
static bool n1x_coordinated_gate_checked,n1x_coordinated_gate_allowed;
static int n1x_coordinated_gate_lock;
static bool good_vendor=true,n1x=true;
static const char *product="ProArt P16 H7607BA";
static bool osc_os_lpi_support_confirmed,osi_supported;
static bool acpi_processor_ffh_lpi_hierarchy_supported(void){return osi_supported;}
static bool dmi_match(int field,const char *value){assert(field==DMI_SYS_VENDOR);assert(!strcmp(value,"ASUS"));return good_vendor;}
static const char *dmi_get_system_info(int field){assert(field==DMI_PRODUCT_NAME);return product;}
static bool acpi_dev_present(const char *hid,const char *uid,int rev){(void)uid;(void)rev;assert(!strcmp(hid,"NVDA6210"));return n1x;}
static void reset(void){n1x_coordinated_requested=false;n1x_coordinated_disabled=false;n1x_coordinated_gate_checked=false;n1x_coordinated_gate_allowed=false;good_vendor=true;n1x=true;product="ProArt P16 H7607BA";}
'''
main=r'''
int main(void){
 for(int disable=0;disable<2;disable++)for(int dmi=0;dmi<2;dmi++)for(int ack=0;ack<2;ack++)for(int osi=0;osi<2;osi++){
  reset();if(disable)n1x_coordinated_setup("0");good_vendor=dmi;osc_os_lpi_support_confirmed=ack;osi_supported=osi;
  assert(acpi_lpi_can_coordinate()==(!disable && dmi && ack && osi));
 }
 reset();n1x_coordinated_setup("1");n1x=false;osc_os_lpi_support_confirmed=osi_supported=true;
 assert(!acpi_lpi_can_coordinate());
 puts("PASS actual automatic admission/activation: disable/DMI/OSC/OSI matrix; explicit1 cannot force non-N1X");return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='n1x-lpi-gate-') as td:
 c=Path(td)/'gate.c';exe=Path(td)/'test';c.write_text(prefix+'\n'+function('n1x_coordinated_setup')+'\n'+function('n1x_p16_hardware_matches')+'\n'+function('n1x_coordinated_allowed')+'\n'+function('acpi_lpi_can_coordinate')+'\n'+main)
 subprocess.run(['cc','-std=gnu11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-fsanitize=address,undefined','-g',str(c),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
