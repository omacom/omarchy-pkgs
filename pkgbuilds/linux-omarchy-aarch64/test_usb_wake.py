#!/usr/bin/env python3
"""Compile real lookup/registration/removal statements; no device access."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(__file__).resolve().parent
source=Path(sys.argv[1]); source=source/'drivers/usb/host/xhci-plat.c' if source.is_dir() else source
src=source.read_text()
def block(start):
 pos=src.index(start);br=src.index('{',pos);i=br+1;d=1
 while d:d+=(src[i]=='{')-(src[i]=='}');i+=1
 return src[pos:i]
helper=''
if 'static int xhci_plat_mtk_get_wakeup_irq(' in src:
 helper=block('static int xhci_plat_mtk_get_wakeup_irq(')
 lookup='wakeup_irq = xhci_plat_mtk_get_wakeup_irq(pdev, &wakeup_from_gpio, &wakeup_capable);'
else:
 helper='static int xhci_plat_mtk_get_wakeup_irq(struct platform_device*p,bool*f,bool*w){*f=false;*w=false;return platform_get_irq_optional(p,1);}'
 lookup='wakeup_irq = platform_get_irq_optional(pdev, 1);'
registration=block('if (wakeup_irq > 0)')
# Remove a real block if present; baseline lacks the new wake-state cleanup.
needle='if (priv->is_mtk_v2) {\n\t\tdev_pm_clear_wake_irq'
remove=block(needle) if needle in src else 'if (priv->is_mtk_v2) dev_pm_clear_wake_irq(&dev->dev);'
prefix=r'''
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#define EPROBE_DEFER 517
struct acpi_device {int x;};struct device {struct acpi_device*acpi;};struct platform_device {struct device dev;};
struct xhci_plat_priv{bool is_mtk_v2;};
#define ACPI_COMPANION(d) ((d)->acpi)
#define dev_dbg(...) ((void)0)
#define dev_info(...) ((void)0)
#define dev_err(...) ((void)0)
static int gpio_irq,normal_irq,gpio_calls,normal_calls;static bool gpio_wake;
static int set_ret,init_ret,set_calls,clear_calls,init_calls;static bool enabled;
static int acpi_dev_gpio_irq_wake_get(struct acpi_device*a,int index,bool*w){(void)a;if(index!=0)return -999;gpio_calls++;*w=gpio_wake;return gpio_irq;}
static int platform_get_irq_optional(struct platform_device*p,int index){(void)p;if(index!=1)return -999;normal_calls++;return normal_irq;}
static int dev_pm_set_dedicated_wake_irq_reverse(struct device*d,int irq){(void)d;(void)irq;set_calls++;return set_ret;}
static void dev_pm_clear_wake_irq(struct device*d){(void)d;clear_calls++;}
static int device_init_wakeup(struct device*d,bool on){(void)d;init_calls++;enabled=on;return on?init_ret:0;}
'''
wrappers='''
static int probe_lookup(struct platform_device*pdev,struct xhci_plat_priv*priv,bool*wakeup_from_gpio_out,bool*wakeup_capable_out){
 int wakeup_irq=-1;bool wakeup_from_gpio=false,wakeup_capable=false;
 if(priv && priv->is_mtk_v2){LOOKUP}
 *wakeup_from_gpio_out=wakeup_from_gpio;*wakeup_capable_out=wakeup_capable;return wakeup_irq;
}
static int register_wake(struct platform_device*pdev,int wakeup_irq,bool wakeup_from_gpio,bool wakeup_capable){
 int ret=0;(void)wakeup_from_gpio;(void)wakeup_capable;
 REGISTRATION
 return 0;
 dealloc_usb3_hcd:return ret;
}
static void remove_wake(struct platform_device*dev,struct xhci_plat_priv*priv){REMOVAL}
'''.replace('LOOKUP',lookup).replace('REGISTRATION',registration).replace('REMOVAL',remove)
main=r'''
static int checks,failures;
#define CHECK(name,c) do{checks++;if(!(c)){failures++;printf("FAIL %s\n",name);}}while(0)
static void reset(void){gpio_irq=190;normal_irq=70;gpio_wake=true;gpio_calls=normal_calls=set_calls=clear_calls=init_calls=0;set_ret=init_ret=0;enabled=false;}
int main(void){struct acpi_device a;struct platform_device p={{&a}};struct xhci_plat_priv priv={true};bool f,w;int irq;
 reset();irq=probe_lookup(&p,&priv,&f,&w);CHECK("wake GPIO preferred over ordinary IRQ",irq==190&&f&&w&&normal_calls==0);CHECK("GPIO index zero",gpio_calls==1);
 reset();gpio_irq=-ENOENT;irq=probe_lookup(&p,&priv,&f,&w);CHECK("missing GPIO falls back",irq==70&&!f&&!w&&normal_calls==1);
 reset();gpio_wake=false;irq=probe_lookup(&p,&priv,&f,&w);CHECK("non-wake GPIO falls back",irq==70&&!f&&!w);
 reset();gpio_irq=-EINVAL;irq=probe_lookup(&p,&priv,&f,&w);CHECK("unresolvable GPIO falls back",irq==70&&!f&&!w);
 reset();gpio_irq=-EPROBE_DEFER;irq=probe_lookup(&p,&priv,&f,&w);CHECK("GPIO defer preserved without fallback",irq==-EPROBE_DEFER&&normal_calls==0);
 reset();p.dev.acpi=NULL;irq=probe_lookup(&p,&priv,&f,&w);CHECK("no ACPI uses old lookup",irq==70&&gpio_calls==0);p.dev.acpi=&a;
 reset();priv.is_mtk_v2=false;irq=probe_lookup(&p,&priv,&f,&w);CHECK("non-MTK skips GPIO and IRQ lookup",irq==-1&&gpio_calls==0&&normal_calls==0);priv.is_mtk_v2=true;
 reset();irq=probe_lookup(&p,NULL,&f,&w);CHECK("no MTK private data skips lookup",irq==-1&&gpio_calls==0&&normal_calls==0);
 reset();int ret=register_wake(&p,190,true,true);CHECK("firmware wake capable enables by default",ret==0&&set_calls==1&&enabled&&init_calls==1);
 remove_wake(&p,&priv);CHECK("MTK remove releases IRQ and wake source",clear_calls==1&&!enabled&&init_calls==2);
 reset();ret=register_wake(&p,70,false,false);CHECK("ordinary IRQ retains previous wake default",ret==0&&set_calls==1&&!enabled&&init_calls==0);
 reset();set_ret=-EBUSY;ret=register_wake(&p,190,true,true);CHECK("IRQ registration failure propagates",ret==-EBUSY&&init_calls==0);
 reset();init_ret=-ENOMEM;ret=register_wake(&p,190,true,true);CHECK("wake initialization failure unwinds",ret==-ENOMEM&&!enabled&&clear_calls==1&&init_calls==2);
 reset();priv.is_mtk_v2=false;remove_wake(&p,&priv);CHECK("non-MTK removal untouched",clear_calls==0&&init_calls==0);
 printf("%d checks, %d failures\n",checks,failures);return failures?1:0;}
'''
with tempfile.TemporaryDirectory(prefix='p16-xhci-wake-') as temp:
 p=Path(temp)/'test.c';p.write_text(prefix+helper+wrappers+main);exe=p.with_suffix('')
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Wno-unused-function','-fsanitize=address,undefined',str(p),'-o',str(exe)],check=True)
 raise SystemExit(subprocess.run([str(exe)]).returncode)
