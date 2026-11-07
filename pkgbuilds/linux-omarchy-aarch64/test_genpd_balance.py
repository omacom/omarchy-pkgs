#!/usr/bin/env python3
"""Exercise the actual genpd sync accounting functions with controlled providers."""
from pathlib import Path
import sys
KERNEL_SOURCE = Path(sys.argv[1]).resolve()
import subprocess
import tempfile

SOURCE = KERNEL_SOURCE / 'drivers/pmdomain/core.c'


def function(text, name):
    marker = text.index('static ', text.index(name) - 80)
    # Find the definition rather than a comment/call mentioning the name.
    import re
    match = re.search(r'static (?:bool|int|void) ' + name + r'\([^;]+?\n\{', text)
    assert match, name
    start = match.start()
    brace = text.index('{', match.start())
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


text = SOURCE.read_text()
names = ['genpd_state_disabled', 'genpd_deepest_enabled_state',
         'genpd_child_allows_parent_power_off', 'genpd_sync_power_off',
         'genpd_sync_power_on']
code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#define READ_ONCE(x) (x)
#define GENPD_STATE_ON 0
#define GENPD_STATE_OFF 1
struct list_head { struct list_head *next, *prev; };
#define INIT_LIST_HEAD(p) ((p)->next=(p)->prev=(p))
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define list_for_each_entry(p,h,m) \
 for (p=container_of((h)->next,__typeof__(*p),m); &(p)->m!=(h); \
      p=container_of((p)->m.next,__typeof__(*p),m))
static void add(struct list_head *n, struct list_head *h) {
 n->next=h; n->prev=h->prev; h->prev->next=n; h->prev=n;
}
struct state { bool disable; unsigned usage,usage_s2idle,rejected; };
struct governor { bool (*system_power_down_ok)(void *); };
struct generic_pm_domain {
 unsigned state_idx,state_count,suspended_count,device_count;
 int status,sd_count,off_calls,on_calls,off_error;
 bool always_on;
 struct state states[2];
 struct list_head parent_links,child_links;
 struct governor *gov;
 int domain;
};
struct gpd_link {
 struct generic_pm_domain *parent,*child;
 struct list_head parent_node,child_node;
};
#define atomic_read(p) (*(p))
#define genpd_status_on(p) ((p)->status==GENPD_STATE_ON)
#define genpd_is_always_on(p) ((p)->always_on)
#define genpd_sd_counter_dec(p) (--(p)->sd_count)
#define genpd_sd_counter_inc(p) (++(p)->sd_count)
#define genpd_lock_nested(p,d) ((void)(p),(void)(d))
#define genpd_unlock(p) ((void)(p))
static int _genpd_power_off(struct generic_pm_domain *p,bool unused) {
 (void)unused; p->off_calls++; return p->off_error;
}
static int _genpd_power_on(struct generic_pm_domain *p,bool unused) {
 (void)unused; p->on_calls++; return 0;
}
static void init(struct generic_pm_domain *p) {
 *p=(struct generic_pm_domain){.state_count=1,.device_count=1,.suspended_count=1};
 INIT_LIST_HEAD(&p->parent_links); INIT_LIST_HEAD(&p->child_links);
}
'''
code += '\n'.join(function(text, name) for name in names)
code += r'''
int main(void) {
 struct generic_pm_domain leaf,parent;
 struct gpd_link link;
 init(&leaf); init(&parent); parent.device_count=parent.suspended_count=0;
 parent.sd_count=1; parent.off_error=-16;
 link.parent=&parent; link.child=&leaf;
 add(&link.parent_node,&parent.parent_links);
 add(&link.child_node,&leaf.child_links);
 /* A shared-provider rejection cannot publish shared OFF or usage. */
 genpd_sync_power_off(&leaf,true,true,0);
 assert(leaf.status==GENPD_STATE_OFF && leaf.states[0].usage_s2idle==1);
 assert(parent.status==GENPD_STATE_ON && parent.states[0].usage==0);
 assert(parent.states[0].rejected==1 && parent.sd_count==0);
 genpd_sync_power_on(&leaf,true,0);
 assert(leaf.status==GENPD_STATE_ON && parent.sd_count==1);
 assert(leaf.on_calls==1 && parent.on_calls==0);
 /* A subsequent successful cycle balances both domains exactly once. */
 parent.off_error=0;
 genpd_sync_power_off(&leaf,true,true,0);
 assert(parent.status==GENPD_STATE_OFF && parent.states[0].usage_s2idle==1);
 genpd_sync_power_on(&leaf,true,0);
 assert(parent.status==GENPD_STATE_ON && parent.sd_count==1);
 assert(parent.on_calls==1 && leaf.on_calls==2);
 /* Disabled leaf states cannot propagate a false last-child transition. */
 leaf.states[0].disable=true;
 genpd_sync_power_off(&leaf,true,true,0);
 assert(leaf.status==GENPD_STATE_ON && parent.sd_count==1);
 assert(parent.off_calls==2);
 puts("PASS: actual genpd rejection/partial-off/resume accounting and disabled-state propagation");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'test.c'
    binary = Path(tmp) / 'test'
    source.write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                    '-fsanitize=address,undefined', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
