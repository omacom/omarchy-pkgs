#!/usr/bin/env python3
"""Exercise the driver's query/ioctl functions with injected OS and RPC edges."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def main():
    source = (ROOT / 'n1x_pluton.c').read_text()
    constants = source[source.index('#define N1X_ROT_IN_DATA '):
                       source.index('static bool enable_transport;')]
    state = source[source.index('struct n1x_pluton {'):
                   source.index('static int n1x_rot_wait(')]
    init = source[source.index('static int n1x_rot_init('):
                  source.index('static int n1x_rot_message(')]
    ioctls = source[source.index('static long n1x_pluton_query_ioctl('):
                    source.index('static void n1x_pluton_free(')]
    code = r'''
#define _DEFAULT_SOURCE
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "n1x_pluton_uapi.h"
#include "n1x_pluton_protocol.h"
#include "n1x_pcbi_protocol.h"
typedef uint8_t u8;typedef uint32_t u32;
struct kref {int unused;};struct miscdevice {int unused;};
struct mutex {pthread_mutex_t native;};struct file {void *private_data;};
#define __user
#define __iomem
#define GFP_KERNEL 0
#define CAP_SYS_RAWIO 17
#define U8_MAX UINT8_MAX
#define BIT(n) (1U << (n))
#define u64_to_user_ptr(x) ((void *)(uintptr_t)(x))
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((long)(intptr_t)(p))
static unsigned long jiffies=123;
static unsigned long msecs_to_jiffies(unsigned long n) {return n;}
static bool enable_transport;
''' + constants + state + r'''
static struct n1x_pluton device;
static u32 registers[64];
static atomic_uint calls,allocations,active_rpc,max_rpc;
static unsigned writes;
static int wait_error,flush_error;
static _Thread_local unsigned locked;
static _Thread_local struct n1x_pluton_query *user_query;
static _Thread_local bool fail_from,fail_descriptor,fail_payload,fail_access,fail_alloc,raw_cap;
static _Thread_local int lock_error,rpc_error,reply_fault;
static int mutex_lock_interruptible(struct mutex *lock)
{if(lock_error)return lock_error;assert(!locked);assert(!pthread_mutex_lock(&lock->native));locked=1;return 0;}
static void mutex_unlock(struct mutex *lock)
{assert(locked);locked=0;assert(!pthread_mutex_unlock(&lock->native));}
static bool capable(int cap) {assert(cap==CAP_SYS_RAWIO);return raw_cap;}
static unsigned long copy_from_user(void *dst,const void *src,size_t n)
{if(fail_from)return n;memcpy(dst,src,n);return 0;}
static unsigned long copy_to_user(void *dst,const void *src,size_t n)
{if((dst==user_query && fail_descriptor)||(dst!=user_query && fail_payload))return n;
 memcpy(dst,src,n);return 0;}
static bool access_ok(const void *p,size_t n) {return p && n && !fail_access;}
static void *kvzalloc(size_t n,int flags)
{assert(!flags && !locked);if(fail_alloc)return NULL;void *p=calloc(1,n);assert(p);allocations++;return p;}
static void kvfree(void *p) {if(p){assert(allocations);allocations--;free(p);}}
static u32 ioread32(const void *p) {assert(locked);return *(const u32 *)p;}
static void iowrite32(u32 value,void *p) {assert(locked);writes++;*(u32 *)p=value;}
static int n1x_rot_flush(struct n1x_pluton *p,unsigned int status,unsigned int ack)
{assert(p==&device && locked && status && ack);return flush_error;}
static int n1x_rot_wait(struct n1x_pluton *p,unsigned int reg,unsigned long deadline)
{assert(p==&device && locked && reg==N1X_ROT_READY && deadline==jiffies+10000);return wait_error;}
''' + init + r'''
static void put32(u8 *p,u32 n) {for(unsigned i=0;i<4;i++)p[i]=n>>(8*i);}
static int n1x_pfi_channels(struct n1x_pluton *p,struct n1x_pluton_channels *channels,
 unsigned long deadline)
{assert(p==&device && locked && deadline==jiffies+10000);memset(channels,0,sizeof(*channels));return 0;}
static int n1x_pluton_rpc(struct n1x_pluton *p,struct n1x_pluton_transfer *exchange,
 const u8 *tx,u8 *rx,unsigned long deadline)
{
 assert(p==&device && locked && deadline==jiffies+10000);
 assert(exchange->channel==1 && exchange->tx_size==12 && !exchange->rx_actual);
 assert(exchange->rx_size==n1x_pcbi_query_capacity(tx[8]));
 const u8 expected[]={1,1,0,0,1,1,0,0,tx[8],0,0,0};assert(!memcmp(tx,expected,12));
 calls++;unsigned concurrent=++active_rpc;unsigned previous=max_rpc;
 while(previous<concurrent && !atomic_compare_exchange_weak(&max_rpc,&previous,concurrent)){}
 usleep(1000);active_rpc--;
 if(rpc_error){p->poisoned=true;return rpc_error;}
 const u8 header[]={1,1,0,0,1,2,0,0,tx[8],0,0,0,0xbd,0xac,0x86,0x79};
 memcpy(rx,header,16);
 switch(tx[8]){
 case 7:rx[2]=2;rx[16]=1;rx[17]=1;exchange->rx_actual=18;break;
 case 5:rx[2]=8;put32(rx+16,2);memcpy(rx+20,(u8[]){1,1,2,1},4);exchange->rx_actual=24;break;
 case 4:rx[2]=52;rx[16]=6;rx[17]=1;memcpy(rx+24,"PltnFull",8);
        rx[56]=1;rx[57]=6;rx[58]=8;exchange->rx_actual=68;break;
 default:abort();
 }
 if(reply_fault==1)rx[8]^=1;
 if(reply_fault==2){rx[2]=0;put32(rx+12,0x12345678);exchange->rx_actual=16;}
 if(reply_fault==3)exchange->rx_actual=15;
 if(reply_fault==4)exchange->rx_actual=exchange->rx_size+1;
 return 0;
}
''' + ioctls + r'''
static struct n1x_pluton_query query;
static u8 output[4096];
static struct file file={.private_data=&device};
static void reset(void)
{
 assert(!locked && !allocations && !active_rpc);
 device.last_pfi_status=0;device.initialized=true;
 device.poisoned=device.removed=device.suspended=false;
 enable_transport=true;
 calls=max_rpc=writes=0;flush_error=wait_error=0;
 fail_from=fail_descriptor=fail_payload=fail_access=fail_alloc=raw_cap=false;
 lock_error=rpc_error=reply_fault=0;
 memset(&query,0,sizeof(query));memset(output,0xa5,sizeof(output));
 query.command=7;query.rx_size=1024;query.rx_ptr=(uintptr_t)output;user_query=&query;
}
static long invoke(void)
{long ret=n1x_pluton_ioctl(&file,N1X_PLUTON_QUERY,(unsigned long)&query);
 assert(!allocations && !locked && !active_rpc);return ret;}
static void untouched(void) {for(unsigned i=0;i<sizeof(output);i++)assert(output[i]==0xa5);}
static void *thread_query(void *arg)
{
 unsigned command=(uintptr_t)arg;u8 rx[4096];
 struct n1x_pluton_query local={.command=command,.rx_size=n1x_pcbi_query_capacity(command),
                              .rx_ptr=(uintptr_t)rx};
 user_query=&local;assert(!n1x_pluton_ioctl(&file,N1X_PLUTON_QUERY,(unsigned long)&local));
 assert(local.pcbi_result==N1X_PCBI_SUCCESS && !n1x_pcbi_validate_reply(rx,local.rx_actual,command));
 assert(!locked);return NULL;
}
int main(void)
{
 assert(!pthread_mutex_init(&device.lock.native,NULL));device.regs=registers;
 const unsigned commands[]={4,5,7},lengths[]={68,24,18};
 for(unsigned i=0;i<3;i++){
  reset();query.command=commands[i];query.rx_size=n1x_pcbi_query_capacity(query.command);
  assert(!invoke() && calls==1 && !writes && !device.poisoned);
  assert(query.rx_actual==lengths[i] && query.pcbi_result==N1X_PCBI_SUCCESS);
  assert(!n1x_pcbi_validate_reply(output,query.rx_actual,query.command));
 }
 for(unsigned fault=0;fault<10;fault++){
  reset();switch(fault){
  case 0:query.command=0;break;case 1:query.command=0x10000004;break;
  case 2:query.rx_size=15;break;case 3:query.rx_size=1025;break;
  case 4:query.rx_actual=1;break;case 5:query.pcbi_result=1;break;
  case 6:query.reserved[0]=1;break;case 7:query.reserved[1]=1;break;
  case 8:query.command=3;break;case 9:query.command=2;break;}
  assert(invoke()==-EINVAL && !calls && !writes);untouched();
 }
 for(unsigned fault=0;fault<10;fault++){
  const int errors[]={EFAULT,EFAULT,EFAULT,ENOMEM,EINTR,EOPNOTSUPP,ENODEV,ENODEV,ENOTRECOVERABLE,EFAULT};
  reset();switch(fault){
  case 0:fail_from=true;break;case 1:query.rx_ptr=0;break;case 2:fail_access=true;break;
  case 3:fail_alloc=true;break;case 4:lock_error=-EINTR;break;case 5:enable_transport=false;break;
  case 6:device.removed=true;break;case 7:device.suspended=true;break;case 8:device.poisoned=true;break;
  case 9:device.suspended=true;fail_descriptor=true;break;}
  assert(invoke()==-errors[fault] && !calls && !writes);untouched();
 }
 for(unsigned fault=1;fault<=4;fault++){
  reset();reply_fault=fault;assert(invoke()==(fault==2?-EREMOTEIO:-EPROTO) && calls==1);
  assert(device.poisoned==(fault!=2));untouched();
  if(fault==2)assert(query.pcbi_result==0x12345678 && query.rx_actual==16);
  else {query.rx_actual=query.pcbi_result=0;assert(invoke()==-ENOTRECOVERABLE && calls==1);}
 }
 reset();query.rx_size=16;assert(invoke()==-EMSGSIZE && calls==1 && !device.poisoned);
 assert(query.rx_actual==18 && query.pcbi_result==N1X_PCBI_SUCCESS);untouched();
 reset();rpc_error=-ETIMEDOUT;assert(invoke()==-ETIMEDOUT && calls==1 && device.poisoned);untouched();
 assert(invoke()==-ENOTRECOVERABLE && calls==1);
 reset();fail_payload=true;assert(invoke()==-EFAULT && calls==1 && !device.poisoned);untouched();
 reset();fail_descriptor=true;assert(invoke()==-EFAULT && calls==1 && !device.poisoned);
 for(unsigned stage=0;stage<4;stage++){
  reset();device.initialized=false;registers[N1X_ROT_ERROR_STATUS/4-4]=0;
  if(stage==1)flush_error=-EBUSY;if(stage==2)wait_error=-ETIMEDOUT;
  if(stage==3)registers[N1X_ROT_ERROR_STATUS/4-4]=1;
  long ret=invoke();assert(writes==3);
  if(!stage)assert(!ret && calls==1 && device.initialized && !device.poisoned);
  else assert(ret==(stage==1?-EBUSY:stage==2?-ETIMEDOUT:-EIO) && !calls && device.poisoned);
 }
 reset();assert(n1x_pluton_ioctl(&file,N1X_PLUTON_CHANNELS,0)==-ENOTTY && !calls && !writes);
 reset();raw_cap=true;assert(n1x_pluton_ioctl(&file,0xc0285002U,0)==-ENOTTY);
 raw_cap=false;assert(n1x_pluton_ioctl(&file,0xc0285002U,0)==-ENOTTY);
 assert(n1x_pluton_ioctl(&file,0,0)==-ENOTTY && !calls && !writes);
 reset();pthread_t threads[8];
 for(unsigned i=0;i<8;i++)assert(!pthread_create(&threads[i],NULL,thread_query,(void *)(uintptr_t)commands[i%3]));
 for(unsigned i=0;i<8;i++)assert(!pthread_join(threads[i],NULL));
 assert(calls==8 && max_rpc==1 && !allocations && !active_rpc && !device.poisoned);
 assert(!pthread_mutex_destroy(&device.lock.native));
 puts("Pluton typed query: ioctl gates, canonical requests, reply faults, user-copy faults and eight serialized callers: PASS");
 return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix='pluton-query-') as tmp:
        tmp = Path(tmp)
        unit = tmp / 'query.c'
        binary = tmp / 'query'
        unit.write_text(code)
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-Wno-misleading-indentation', '-fsanitize=address,undefined',
                        '-pthread', '-g', '-I', str(ROOT), str(unit), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
