#!/usr/bin/python
"""Compile actual initializer gate and test source ordering before register map."""
from pathlib import Path
import subprocess,tempfile,os
root=Path(__file__).resolve().parent
p=Path(os.environ.get('N1X_SOURCE_ROOT', root/'src/n1x-npu'))/'driver/n1x_npu_boot_linux.c'
s=p.read_text();start=s.index('static int __init n1x_boot_init(void)');end=s.index('\nmodule_init(n1x_boot_init)',start)
body=s[start:end]
shim='''#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <stddef.h>
#define __init
#define CONFIG_ARM64 1
static unsigned page_size=4096;
#define PAGE_SIZE page_size
#define IS_ENABLED(x) (x)
static bool enable;
static unsigned firmware_variant,registered;
static int n1x_boot_driver,n1x_debugfs_status_fops,n1x_debugfs_hfrp_status_fops,n1x_debugfs_shutdown_status_fops;
static void *boot_debugfs_dir;
static int platform_driver_register(int *p) {(void)p;registered++;return 0;}
static void *debugfs_create_dir(const char *n,void *p) {(void)n;return p;}
static void debugfs_create_file(const char *n,int m,void *p,void *d,int *ops) {(void)n;(void)m;(void)p;(void)d;(void)ops;}
'''
test='''int main(void){assert(n1x_boot_init()==-ENODEV&&!registered);enable=true;page_size=16384;assert(n1x_boot_init()==-ENODEV&&!registered);page_size=65536;assert(n1x_boot_init()==-ENODEV&&!registered);page_size=4096;firmware_variant=2;assert(n1x_boot_init()==-EINVAL&&!registered);firmware_variant=0;assert(!n1x_boot_init()&&registered==1);}
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp);(p/'test.c').write_text(shim+body+test)
 subprocess.run(['cc','-Wall','-Wextra','-Werror','-fsanitize=undefined',str(p/'test.c'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
assert 'MODULE_DEVICE_TABLE(acpi' not in s
probe=s[s.index('static int n1x_boot_probe('):s.index('static bool boot_suspended')]
assert probe.index('n1x_boot_dma_gate(endpoint)') < probe.index('devm_ioremap_resource(')
print('Explicit opt-in C gate and early DMA check ordering passed; no hardware')
