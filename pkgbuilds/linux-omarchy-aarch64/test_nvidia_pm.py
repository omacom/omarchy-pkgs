#!/usr/bin/env python3
"""Execute the packaged PM callbacks with worker ownership and failure injection."""
from pathlib import Path
import subprocess
import sys
import tempfile

text = (Path(sys.argv[1]) / 'kernel-open/nvidia/nv.c').read_text()
start = text.index('static struct {\n    struct completion prepared;')
end = text.index('\n}\n', text.index('static int nv_pm_notifier(', start)) + 3
actual = text[start:end]
prelude = r'''
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
typedef int NV_STATUS;
typedef int nv_power_state_t;
#define NV_OK 0
#define NV_POWER_STATE_IN_STANDBY 1
#define NV_POWER_STATE_IN_HIBERNATE 2
#define NV_POWER_STATE_RUNNING 0
#define PM_SUSPEND_PREPARE 1
#define PM_HIBERNATION_PREPARE 2
#define PM_POST_SUSPEND 3
#define PM_POST_HIBERNATION 4
#define NOTIFY_OK 2
#define NOTIFY_DONE 0
#define NOTIFY_BAD 1
#define THIS_MODULE 0
#define NV_DBG_ERRORS 0
#define TASK_INTERRUPTIBLE 1
#define TASK_RUNNING 0
#define IS_ERR(p) ((intptr_t)(p) == -ENOMEM)
struct notifier_block { int unused; };
struct completion { pthread_mutex_t lock; pthread_cond_t cond; bool ready; };
struct task_struct { pthread_t thread; int (*fn)(void *); void *arg; int result; bool stop; pthread_mutex_t lock; pthread_cond_t cond; };
static _Thread_local struct task_struct *self;
static int refs, prepares, posts, fail_prepare, fail_resume, fail_thread;
static bool held;
static pthread_t owner;
static int nv_procfs_pm_action_depth;
static void nv_printf(int level, const char *fmt, ...) {(void)level;(void)fmt;}
static bool try_module_get(int x) {(void)x;refs++;return true;}
static void module_put(int x) {(void)x;assert(refs==1);refs--;}
static void init_completion(struct completion *c) { *c=(struct completion){PTHREAD_MUTEX_INITIALIZER,PTHREAD_COND_INITIALIZER,false}; }
static void complete(struct completion *c) {pthread_mutex_lock(&c->lock);c->ready=true;pthread_cond_signal(&c->cond);pthread_mutex_unlock(&c->lock);}
static void wait_for_completion(struct completion *c) {pthread_mutex_lock(&c->lock);while(!c->ready)pthread_cond_wait(&c->cond,&c->lock);pthread_mutex_unlock(&c->lock);}
static void *run(void *p) {self=p;self->result=self->fn(self->arg);return NULL;}
static struct task_struct *kthread_run(int (*fn)(void *),void *arg,const char *name) {
 (void)name;if(fail_thread)return (void *)(intptr_t)-ENOMEM;
 struct task_struct *t=calloc(1,sizeof(*t));assert(t);t->fn=fn;t->arg=arg;
 pthread_mutex_init(&t->lock,NULL);pthread_cond_init(&t->cond,NULL);assert(!pthread_create(&t->thread,NULL,run,t));return t;
}
static bool kthread_should_stop(void) {pthread_mutex_lock(&self->lock);bool v=self->stop;pthread_mutex_unlock(&self->lock);return v;}
static void schedule(void) {pthread_mutex_lock(&self->lock);while(!self->stop)pthread_cond_wait(&self->cond,&self->lock);pthread_mutex_unlock(&self->lock);}
static void set_current_state(int state) {(void)state;}
static void __set_current_state(int state) {(void)state;}
static int kthread_stop(struct task_struct *t) {pthread_mutex_lock(&t->lock);t->stop=true;pthread_cond_signal(&t->cond);pthread_mutex_unlock(&t->lock);assert(!pthread_join(t->thread,NULL));int rc=t->result;pthread_mutex_destroy(&t->lock);pthread_cond_destroy(&t->cond);free(t);return rc;}
static NV_STATUS nv_set_system_power_state(nv_power_state_t state,int depth) {
 (void)depth;assert(self);assert(!pthread_equal(pthread_self(),(pthread_t)0));
 if(state!=NV_POWER_STATE_RUNNING){prepares++;if(fail_prepare)return 7;assert(!held);held=true;owner=pthread_self();return NV_OK;}
 assert(held && pthread_equal(owner,pthread_self()));held=false;posts++;return fail_resume?8:NV_OK;
}
'''
main = r'''
int main(void) {
 struct notifier_block nb={0};
 assert(nv_pm_notifier(&nb,99,NULL)==NOTIFY_DONE);
 assert(nv_pm_notifier(&nb,PM_POST_SUSPEND,NULL)==NOTIFY_DONE);
 for(int mode=0;mode<4;mode++){
  fail_thread=mode==1;fail_prepare=mode==2;fail_resume=mode==3;
  int rc=nv_pm_notifier(&nb,PM_SUSPEND_PREPARE,NULL);
  if(mode==1 || mode==2){assert(rc==NOTIFY_BAD);assert(!held && !refs && !nv_pm_context.task);}
  else {assert(rc==NOTIFY_OK && held && refs==1);assert(nv_pm_notifier(&nb,PM_SUSPEND_PREPARE,NULL)==NOTIFY_BAD);assert(nv_pm_notifier(&nb,PM_POST_SUSPEND,NULL)==(mode==3?NOTIFY_BAD:NOTIFY_OK));assert(!held && !refs && !nv_pm_context.task);}
 }
 fail_thread=fail_prepare=fail_resume=0;
 assert(nv_pm_notifier(&nb,PM_HIBERNATION_PREPARE,NULL)==NOTIFY_OK);
 assert(nv_pm_notifier(&nb,PM_POST_HIBERNATION,NULL)==NOTIFY_OK);
 assert(prepares==4 && posts==3 && !refs && !held);
 puts("PASS PM worker ownership, duplicate prepare, thread/prepare/resume failures, post/hibernate cleanup");
}
'''
with tempfile.TemporaryDirectory() as temp:
    source, binary = Path(temp) / 'pm.c', Path(temp) / 'pm'
    source.write_text(prelude + actual + main)
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-pthread', '-fsanitize=undefined',
                    str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], timeout=10, check=True)
