#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compile actual decoded-length, header validation and HID request callbacks."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def extract(source, name):
    match = re.search(r'static (?:void|int) ' + name + r'\(', source)
    start = match.start()
    return source[start:source.index('\n}\n', start) + 3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_root', type=Path)
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    args.source = args.kernel_root / 'drivers/hid/spi-hid/spi-hid-core.c'
    source = args.source.read_text()
    structures = '\n'.join(re.search(r'struct ' + name + r' \{.*?\n\};', source, re.S).group()
                           for name in ['spi_hid_input_header', 'spi_hid_input_body'])
    functions = '\n'.join(extract(source, name) for name in
                          ['spi_hid_populate_input_header', 'spi_hid_populate_input_body',
                           'spi_hid_bus_validate_header', 'spi_hid_ll_request'])
    code = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint8_t u8;typedef uint16_t u16;
#define SPI_HID_INPUT_HEADER_VERSION 3
#define SPI_HID_INPUT_HEADER_SYNC_BYTE 0x5a
#define HID_INPUT_REPORT 0
#define HID_FEATURE_REPORT 2
#define HID_REQ_GET_REPORT 1
#define HID_REQ_SET_REPORT 2
#define dev_err(dev,...) ((void)(dev))
#define hid_dbg(dev,...) ((void)(dev))
static u16 get_unaligned_le16(const u8 *b){return (u16)b[0]|((u16)b[1]<<8);}
struct device {int unused;};
struct spi_device {struct device dev;};
struct spi_hid {struct spi_device *spi;struct {u16 max_input_length;} desc;bool input_stream_only;};
struct hid_device {void *driver_data;};
struct hid_report {int type;};
static struct spi_device spi;
static struct spi_hid shid={.spi=&spi};
static unsigned requests;
static int request_error;
static void *spi_get_drvdata(struct spi_device *s){assert(s==&spi);return &shid;}
static int __hid_request(struct hid_device *h,struct hid_report *r,int type)
{(void)h;(void)r;(void)type;requests++;return request_error;}
''' + structures + '\n' + functions + r'''
int main(void){
 struct spi_hid_input_body body;
 struct spi_hid_input_header header;
 const u8 raw_body[]={7,0x34,0x12,0x88};
 spi_hid_populate_input_body(raw_body,&body);
 assert(body.input_report_type==7 && body.content_len==0x1234 && body.content_id==0x88);
 _Static_assert(__builtin_types_compatible_p(__typeof__(body.content_len),u16),"decoded native u16");
 for(unsigned n=0;n<=0x3fff;n++){
  u8 raw_header[]={3,n&255,((n>>8)&0x3f)|0x40,0x5a};
  spi_hid_populate_input_header(raw_header,&header);
  assert(header.version==3 && header.report_length==n*4 && header.last_fragment_flag==1);
  assert(!spi_hid_bus_validate_header(&shid,&header));
 }
 header=(struct spi_hid_input_header){3,100,1,0x5a};
 shid.desc.max_input_length=100;assert(!spi_hid_bus_validate_header(&shid,&header));
 header.report_length=104;assert(spi_hid_bus_validate_header(&shid,&header)==-EMSGSIZE);
 header.report_length=100;header.version=2;assert(spi_hid_bus_validate_header(&shid,&header)==-EINVAL);
 header.version=3;header.last_fragment_flag=0;assert(spi_hid_bus_validate_header(&shid,&header)==-EOPNOTSUPP);
 header.last_fragment_flag=1;header.sync_const=0;assert(spi_hid_bus_validate_header(&shid,&header)==-EINVAL);
 struct hid_device hid={.driver_data=&spi};struct hid_report report={.type=HID_INPUT_REPORT};
 shid.input_stream_only=true;
 spi_hid_ll_request(&hid,&report,HID_REQ_GET_REPORT);assert(requests==0);
 report.type=HID_FEATURE_REPORT;spi_hid_ll_request(&hid,&report,HID_REQ_GET_REPORT);assert(requests==1);
 report.type=HID_INPUT_REPORT;spi_hid_ll_request(&hid,&report,HID_REQ_SET_REPORT);assert(requests==2);
 shid.input_stream_only=false;spi_hid_ll_request(&hid,&report,HID_REQ_GET_REPORT);assert(requests==3);
 request_error=-EIO;spi_hid_ll_request(&hid,&report,HID_REQ_GET_REPORT);assert(requests==4);
 puts("SPI HID actual C decoded lengths, header bounds, stream-only request dispatch: PASS");
}
'''
    with tempfile.TemporaryDirectory(prefix='p16-spi-lengths-') as temporary:
        cfile, binary = Path(temporary) / 'lengths.c', Path(temporary) / 'lengths'
        cfile.write_text(code)
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-g', str(cfile), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    main()
