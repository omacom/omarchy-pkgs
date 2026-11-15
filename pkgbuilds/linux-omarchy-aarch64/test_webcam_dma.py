#!/usr/bin/env python3
"""Execute actual probe DMA setup and actual xHCI count/split expressions."""
from pathlib import Path
import re,subprocess,sys,tempfile
src=Path(sys.argv[1]);plat=(src/'drivers/usb/host/xhci-plat.c').read_text();ring=(src/'drivers/usb/host/xhci-ring.c').read_text();header=(src/'drivers/usb/host/xhci.h').read_text()
probe=plat[plat.index('\tif (!sysdev)',plat.index('int xhci_plat_probe(')):plat.index('\n\tpm_runtime_set_active',plat.index('int xhci_plat_probe('))]
count=re.search(r'unsigned int count_trbs\(u64 addr, u64 len\)\n\{.*?\n\}',ring,re.S)[0]
macro=re.search(r'#define TRB_BUFF_LEN_UP_TO_BOUNDARY\(addr\).*',header)[0]
if macro.endswith('\\'):macro+='\n'+header.split(macro+'\n')[1].splitlines()[0]
split=re.search(r'trb_buff_len = TRB_BUFF_LEN_UP_TO_BOUNDARY\(addr\);\n\s*if \(trb_buff_len > td_remain_len\)\n\s*trb_buff_len = td_remain_len;',ring)[0]
code='''#include <stdint.h>
#include <limits.h>
#include <assert.h>
#include <stdio.h>
typedef uint64_t u64;
#define TRB_MAX_BUFF_SIZE 65536U
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define DMA_BIT_MASK(n) UINT64_MAX
struct parms {unsigned int max_segment_size;};
struct device {struct parms *dma_parms;};
struct platform_device {struct device dev;};
static int mask_error;
static int dma_set_mask_and_coherent(struct device *d,u64 mask){(void)d;(void)mask;return mask_error;}
static void dma_set_max_seg_size(struct device *d,unsigned int n){d->dma_parms->max_segment_size=n;}
static int setup(struct platform_device *pdev,struct device *sysdev){int ret;
'''+probe+'''\nreturn 0;}\n'''+macro+'\n'+count+'''\nint main(void){
struct parms a={0},b={32768};struct platform_device p={{&a}};struct device parent={&b},none={0};
assert(setup(&p,0)==0);assert(a.max_segment_size>=94208);
assert(setup(&p,&parent)==0);assert(b.max_segment_size>=94208);
assert(setup(&p,&none)==0);
a.max_segment_size=0;mask_error=-7;assert(setup(&p,0)==-7);assert(a.max_segment_size==0);
for(u64 start=0;start<65536;start+=17){for(u64 len=1;len<=188416;len+=4096){
u64 addr=start,td_remain_len=len;unsigned n=0,trb_buff_len;
while(td_remain_len){\n'''+split+'''\nassert(trb_buff_len&&trb_buff_len<=65536);assert((addr&65535)+trb_buff_len<=65536);
addr+=trb_buff_len;td_remain_len-=trb_buff_len;n++;}
assert(n==count_trbs(start,len));}}
printf("PASS probe DMA-device selection, allocation error and TRB split boundaries\\n");}
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'test.c').write_text(code);subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-Wno-unused-function',str(p/'test.c'),'-o',str(p/'test')],check=True);subprocess.run([str(p/'test')],check=True)
