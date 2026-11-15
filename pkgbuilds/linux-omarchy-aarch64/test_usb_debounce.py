#!/usr/bin/env python3
"""Exercise exact pinctrl debounce callback, with no MMIO or source writes."""
from pathlib import Path
import subprocess,sys,tempfile
root=Path(sys.argv[1]);text=(root/'drivers/pinctrl/mediatek/pinctrl-paris.c').read_text()
start=text.index('static int mtk_gpio_set_config(');p=text.index('{',start);i=p+1;depth=1
while depth:depth+=(text[i]=='{')-(text[i]=='}');i+=1
function=text[start:i]
prefix=r'''
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
typedef unsigned u32;
#define ENOTSUPP 524
#define EINT_NA 255
#define PIN_CONFIG_INPUT_DEBOUNCE 1
struct mtk_pin_desc {struct {unsigned eint_n;}eint;};
struct mtk_eint_pin {bool debounce;};
struct mtk_eint {struct mtk_eint_pin*pins;};
struct soc {struct mtk_pin_desc*pins;};
struct mtk_pinctrl {struct soc*soc;struct mtk_eint*eint;};
struct gpio_chip{struct mtk_pinctrl*hw;};
#define gpiochip_get_data(c) ((c)->hw)
#define pinconf_to_config_param(c) ((c)&255)
#define pinconf_to_config_argument(c) ((c)>>8)
static unsigned calls,last_value;static int hardware_ret;
static int mtk_eint_set_debounce(struct mtk_eint*e,unsigned pin,unsigned val){calls++;last_value=val;if(!e->pins[pin].debounce)return -EINVAL;return hardware_ret;}
'''
main=r'''
int main(void){struct mtk_pin_desc pin={{0}};struct mtk_eint_pin einfo={false};struct mtk_eint eint={&einfo};struct soc soc={&pin};struct mtk_pinctrl hw={&soc,&eint};struct gpio_chip chip={&hw};int fail=0,checks=0,ret;
#define CHECK(n,c) do{checks++;if(!(c)){printf("FAIL %s\n",n);fail++;}}while(0)
 ret=mtk_gpio_set_config(&chip,0,1);CHECK("no hardware debounce reports unsupported",ret==-ENOTSUPP&&calls==0);
 einfo.debounce=true;calls=0;ret=mtk_gpio_set_config(&chip,0,1|(1500<<8));CHECK("supported debounce forwarded",ret==0&&calls==1&&last_value==1500);
 hardware_ret=-EIO;ret=mtk_gpio_set_config(&chip,0,1);CHECK("real hardware error preserved",ret==-EIO);
 calls=0;ret=mtk_gpio_set_config(&chip,0,2);CHECK("other setting unsupported without MMIO",ret==-ENOTSUPP&&calls==0);
 hw.eint=NULL;ret=mtk_gpio_set_config(&chip,0,1);CHECK("missing EINT unsupported",ret==-ENOTSUPP);hw.eint=&eint;
 pin.eint.eint_n=EINT_NA;ret=mtk_gpio_set_config(&chip,0,1);CHECK("non EINT pin unsupported",ret==-ENOTSUPP);
 printf("%d checks, %d failures\n",checks,fail);return fail?1:0;}
'''
with tempfile.TemporaryDirectory(prefix='p16-debounce-') as t:
 p=Path(t)/'test.c';p.write_text(prefix+function+main);exe=p.with_suffix('')
 subprocess.run(['cc','-std=c11','-Wall','-Wextra','-fsanitize=address,undefined',str(p),'-o',str(exe)],check=True)
 raise SystemExit(subprocess.run([str(exe)]).returncode)
