#!/usr/bin/env python3
"""Exercise the SROOT coherency function from a prepared kernel source tree.

Uses the supplied Linux source without modifying it. OS/ACPI calls are mocks;
this checks quirk scope and precedence, not actual DMA or firmware operation.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_source', type=Path, help='prepared kernel source tree with the SROOT DMA correction')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='n1x-cca-') as tmp:
        root = Path(tmp)
        target = root/'drivers/acpi/scan.c'
        target.parent.mkdir(parents=True)
        target.write_bytes((args.kernel_source/'drivers/acpi/scan.c').read_bytes())
        source = target.read_text()
        start = source.index('static void acpi_init_coherency(')
        end = source.index('\nstatic int acpi_check_serial_bus_slave', start)
        harness = r'''
#include <assert.h>
#include <string.h>
#include <stddef.h>
typedef int acpi_status;
#define AE_NOT_FOUND 1
#define ACPI_SUCCESS(s) ((s)==0)
#define CONFIG_ACPI_CCA_REQUIRED required
#define IS_ENABLED(x) (x)
enum {DMI_SYS_VENDOR, DMI_PRODUCT_NAME, DMI_BIOS_VERSION};
static int required=1, cca_status=AE_NOT_FOUND, hrv_status, notices;
static unsigned long long cca_value, hrv_value=1;
struct acpi_device {
    struct {unsigned int cca_seen, coherent_dma;} flags;
    struct acpi_device *parent;
    void *handle;
    const char *hid;
};
static struct acpi_device *acpi_dev_parent(struct acpi_device *a) {return a->parent;}
static const char *acpi_device_hid(struct acpi_device *a) {return a->hid;}
static acpi_status acpi_evaluate_integer(void *h,const char *name,void *args,unsigned long long *out)
{(void)h;(void)args; if(!strcmp(name,"_CCA")){if(!cca_status)*out=cca_value;return cca_status;}
 assert(!strcmp(name,"_HRV"));if(!hrv_status)*out=hrv_value;return hrv_status;}
#define acpi_handle_debug(...) ((void)0)
#define acpi_handle_info(...) (notices++)
'''
        harness += source[start:end]
        harness += r'''
static void check(struct acpi_device *parent,const char *hid,unsigned int seen,unsigned int coherent,int notice)
{struct acpi_device a={.parent=parent,.hid=hid};notices=0;
 acpi_init_coherency(&a);assert(a.flags.cca_seen==seen);
 assert(a.flags.coherent_dma==coherent);assert(notices==notice);}
int main(void)
{
 check(NULL,"NVDA8600",1,0,1);
 check(NULL,"NVDA200A",0,0,0);
 hrv_value=2;check(NULL,"NVDA8600",0,0,0);hrv_value=1;
 hrv_status=AE_NOT_FOUND;check(NULL,"NVDA8600",0,0,0);hrv_status=0;
 cca_status=2;check(NULL,"NVDA8600",0,0,0);
 cca_status=0;cca_value=1;check(NULL,"NVDA8600",1,1,0);
 cca_value=0;check(NULL,"NVDA8600",1,0,0);
 cca_status=AE_NOT_FOUND;
 struct acpi_device parent={.flags={.cca_seen=1,.coherent_dma=1}};
 check(&parent,"NVDA8600",1,1,0);
 parent.flags.coherent_dma=0;check(&parent,"NVDA8600",1,0,0);
 required=0;check(NULL,"NVDA8600",0,1,0);
 return 0;
}
'''
        (root/'check.c').write_text(harness)
        subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Wextra', '-Werror',
                        str(root/'check.c'), '-o', str(root/'check')], check=True)
        subprocess.run([str(root/'check')], check=True)
    print('Patched ACPI function: 13 policy/precedence cases passed; source unchanged, no hardware access')


if __name__ == '__main__':
    main()
