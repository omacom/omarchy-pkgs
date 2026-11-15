#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise the driver's GET-report callback with concurrent callers."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_root', type=Path)
    parser.add_argument('--source', type=Path, default=ROOT / 'spi-hid-core.c')
    args = parser.parse_args()
    args.source = args.kernel_root / 'drivers/hid/spi-hid/spi-hid-core.c'
    source = args.source.read_text()
    callback = source[source.index('static int spi_hid_get_request('):
                      source.index('static int spi_hid_set_request(')]
    harness = r'''
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8;
#define HID_INPUT_REPORT 0
#define HID_FEATURE_REPORT 2
#define GET_FEATURE 4
#define GET_INPUT_REPORT 5
#define GET_FEATURE_RESPONSE 6
#define GET_INPUT_REPORT_RESPONSE 7
#define SPI_HID_ERROR 1
#define min_t(type,a,b) ((type)(a)<(type)(b)?(type)(a):(type)(b))
#define dev_err(dev,...) ((void)(dev))
struct device {int unused;};
struct spi_device {struct device dev;};
struct response {u8 body[4],content[16];};
struct spi_hid {
 struct spi_device *spi;
 bool input_stream_only;
 pthread_mutex_t output_lock;
 struct response *response;
 size_t response_length;
 unsigned long flags;
 int reset_work;
};
struct spi_hid_output_report {u8 report_type,content_id;size_t content_length;u8 *content;};
static struct spi_device spi;
static struct response response;
static struct spi_hid shid={.spi=&spi,.response=&response,
 .output_lock=PTHREAD_MUTEX_INITIALIZER};
static pthread_mutex_t events=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
static bool concurrent,copy_waiting,second_lock_attempted,release_copy;
static unsigned calls;
static int query_error,bad_type,bad_id;
static void set_bit(unsigned bit,unsigned long *flags)
{assert(bit==SPI_HID_ERROR);*flags|=1UL<<bit;}
static void schedule_work(int *work)
{assert(work==&shid.reset_work);(*work)++;}
static _Thread_local int caller;
static pthread_mutex_t *lock_output(pthread_mutex_t *mutex)
{
 if(concurrent && caller==2) {
  pthread_mutex_lock(&events);second_lock_attempted=true;
  pthread_cond_broadcast(&condition);pthread_mutex_unlock(&events);
 }
 assert(!pthread_mutex_lock(mutex));return mutex;
}
static void unlock_output(pthread_mutex_t **mutex)
{assert(!pthread_mutex_unlock(*mutex));}
#define guard(kind) pthread_mutex_t *held __attribute__((cleanup(unlock_output)))=lock_output
static int __spi_hid_sync_request(struct spi_hid *s,struct spi_hid_output_report *report)
{
 assert(pthread_mutex_trylock(&s->output_lock)==EBUSY);
 assert(!report->content && !report->content_length);
 calls++;
 if(query_error)return query_error;
 assert(report->report_type==GET_FEATURE || report->report_type==GET_INPUT_REPORT);
 response.body[0]=bad_type?99:
  report->report_type==GET_FEATURE?GET_FEATURE_RESPONSE:GET_INPUT_REPORT_RESPONSE;
 response.body[3]=bad_id?99:report->content_id;
 for(unsigned i=0;i<sizeof(response.content);i++)response.content[i]=report->content_id+i;
 s->response_length=sizeof(response.content);return 0;
}
static void *checked_copy(void *destination,const void *input,size_t length)
{
 assert(pthread_mutex_trylock(&shid.output_lock)==EBUSY);
 if(concurrent && caller==1) {
  pthread_mutex_lock(&events);copy_waiting=true;pthread_cond_broadcast(&condition);
  while(!release_copy)pthread_cond_wait(&condition,&events);
  pthread_mutex_unlock(&events);
 }
 return memcpy(destination,input,length);
}
#define memcpy checked_copy
''' + callback + r'''
static u8 buffers[2][17];
static void *query_thread(void *argument)
{
 caller=(int)(intptr_t)argument;
 int result=spi_hid_get_request(&shid,caller,HID_FEATURE_REPORT,buffers[caller-1],17);
 assert(result==17);return NULL;
}
int main(void)
{
 u8 buffer[20];
 for(unsigned type=0;type<3;type+=2) {
  memset(buffer,0xa5,sizeof(buffer));
  assert(spi_hid_get_request(&shid,8,type,buffer,4)==4);
  assert(buffer[0]==8 && buffer[1]==8 && buffer[3]==10 && buffer[4]==0xa5);
  assert(spi_hid_get_request(&shid,8,type,buffer,1)==1);
  assert(spi_hid_get_request(&shid,8,type,buffer,sizeof(buffer))==17);
 }
 unsigned before=calls;
 assert(spi_hid_get_request(&shid,8,1,buffer,4)==-EOPNOTSUPP);
 assert(spi_hid_get_request(&shid,8,HID_FEATURE_REPORT,buffer,0)==-EINVAL);
 shid.input_stream_only=true;
 assert(spi_hid_get_request(&shid,8,HID_INPUT_REPORT,buffer,4)==-EOPNOTSUPP);
 assert(calls==before);shid.input_stream_only=false;
 for(unsigned fault=0;fault<3;fault++) {
  bad_type=fault==0;bad_id=fault==1;query_error=fault==2?-ETIMEDOUT:0;
  memset(buffer,0xa5,sizeof(buffer));
  assert(spi_hid_get_request(&shid,8,HID_FEATURE_REPORT,buffer,4)==
         (query_error?query_error:-EPROTO));
  for(unsigned i=0;i<sizeof(buffer);i++)assert(buffer[i]==0xa5);
  assert(!pthread_mutex_trylock(&shid.output_lock));pthread_mutex_unlock(&shid.output_lock);
 }
 assert(shid.flags==(1UL<<SPI_HID_ERROR) && shid.reset_work==1);
 bad_type=bad_id=query_error=0;
 concurrent=true;calls=0;
 pthread_t first,second;
 assert(!pthread_create(&first,NULL,query_thread,(void *)(intptr_t)1));
 pthread_mutex_lock(&events);
 while(!copy_waiting)pthread_cond_wait(&condition,&events);
 pthread_mutex_unlock(&events);
 assert(!pthread_create(&second,NULL,query_thread,(void *)(intptr_t)2));
 pthread_mutex_lock(&events);
 while(!second_lock_attempted)pthread_cond_wait(&condition,&events);
 assert(calls==1);release_copy=true;pthread_cond_broadcast(&condition);
 pthread_mutex_unlock(&events);
 assert(!pthread_join(first,NULL));assert(!pthread_join(second,NULL));assert(calls==2);
 for(unsigned i=0;i<2;i++) {
  assert(buffers[i][0]==i+1);
  for(unsigned j=1;j<17;j++)assert(buffers[i][j]==i+j);
 }
 puts("SPI HID GET report types, bounds, failures and concurrent response ownership: PASS");
}
'''
    with tempfile.TemporaryDirectory(prefix='p16-hid-requests-') as directory:
        code, binary = Path(directory) / 'requests.c', Path(directory) / 'requests'
        code.write_text(harness)
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-g', '-pthread',
                        str(code), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    main()
