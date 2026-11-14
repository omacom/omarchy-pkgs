#!/usr/bin/env python3
"""Execute actual MT792x helpers and link removal with modeled RCU predicates."""
from pathlib import Path
import subprocess,tempfile,sys
R=Path(__file__).resolve().parent
PRE=r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
typedef unsigned char u8;
#define IEEE80211_LINK_UNSPECIFIED 16
struct mt76_wcid { unsigned idx; };
struct mt792x_dev { struct { int mutex; struct mt76_wcid *wcid[16]; } mt76; };
struct mt792x_phy { struct mt792x_dev *dev; };
struct mt792x_bss_conf { int live; };
struct mt792x_link_sta { int live; struct mt76_wcid wcid; };
struct mt792x_vif { struct { struct mt792x_link_sta *link[16]; struct mt792x_link_sta deflink; } sta; struct mt792x_bss_conf bss_conf; struct mt792x_bss_conf *link_conf[16]; struct mt792x_phy *phy; };
struct ieee80211_bss_conf { int live; };
struct ieee80211_vif { bool mld; struct ieee80211_bss_conf bss_conf; struct ieee80211_bss_conf *link_conf[16]; struct mt792x_vif drv_priv; };
static int mutex_held,wiphy_held,rcu_held,warnings;
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define ieee80211_vif_is_mld(v) ((v)->mld)
#define lockdep_is_held(p) (mutex_held)
#define lockdep_vif_wiphy_mutex_held(v) (wiphy_held)
#define rcu_dereference_protected(p,c) ((warnings+=!(c)),(p))
#define rcu_dereference_check(p,c) ((warnings+=!(rcu_held||(c))),(p))
#define link_conf_dereference_protected(v,id) rcu_dereference_protected((v)->link_conf[id],wiphy_held)
#define link_conf_dereference_check(v,id) rcu_dereference_check((v)->link_conf[id],wiphy_held)
#define rcu_assign_pointer(p,v) ((p)=(v))
#define rcu_access_pointer(p) (p)
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
static int cleanups;
#define mt76_wcid_cleanup(d,w) (cleanups++)
static void *pending[2]; static int pending_count;
#define kfree_rcu(p,field) (pending[pending_count++]=(p))
#define devm_kfree(dev,p) ((p)->live=0)
#define mt792x_mac_link_bss_remove(dev,mc,ml) ((void)(dev))
'''

def func(text,name):
 start=text.index('static inline struct ',text.rfind('\n}',0,text.index(name))+2) if False else text.rfind('static inline struct ',0,text.index(name))
 end=text.index('\n}',text.index(name))+2
 return text[start:end]+'\n'

def run(tree,fixed):
 h=(tree/'mt792x.h').read_text();main=(tree/'mt7925/main.c').read_text()
 helpers=func(h,'mt792x_vif_to_link(')+func(h,'mt792x_vif_to_bss_conf(')
 start=main.index('\t\tif (mconf != &mvif->bss_conf)',main.index('mt7925_change_vif_links(')) if not fixed else main.index('\t\trcu_assign_pointer(mvif->link_conf[link_id], NULL);',main.index('mt7925_change_vif_links('))
 end=main.index('\n\t}\n\n\tfor_each_set_bit(link_id, &add',start)
 removal=main[start:end]
 cleanup_start=main.index('\t\trcu_assign_pointer(mvif->link_conf[link_id], NULL);', main.index('\nfree:\n', main.index('mt7925_change_vif_links(')))
 cleanup_end=main.index('\n\t}\n',cleanup_start)
 cleanup=main[cleanup_start:cleanup_end]
 body=r'''
int main(void) {
 struct mt792x_dev d={0};struct mt792x_phy phy={.dev=&d};
 struct ieee80211_vif vif={.mld=true};struct mt792x_vif *mvif=&vif.drv_priv;
 struct mt792x_bss_conf dynamic={.live=1};struct ieee80211_bss_conf link={.live=1};
 struct mt792x_bss_conf *mconf=&dynamic;struct mt792x_link_sta sta={.live=1},*mlink=&sta;
 struct mt792x_dev *dev=&d;int link_id=1;
 struct mt792x_bss_conf *mconfs[16]={0};struct mt792x_link_sta *mlinks[16]={0};
 (void)dev;(void)mlink;
 mvif->phy=&phy;mvif->link_conf[1]=mconf;mvif->sta.link[1]=mlink;vif.link_conf[1]=&link;
 for(int mode=0;mode<4;mode++) {
  mutex_held=mode==0;wiphy_held=mode==1;rcu_held=mode==2;warnings=0;
  assert(mt792x_vif_to_link(mvif,1)==mconf);
  assert(warnings==((mode==0||FIXED&&mode<3)?0:1));
  warnings=0;assert(mt792x_vif_to_bss_conf(&vif,1)==&link);
  assert(warnings==((mode==1||FIXED&&mode==2)?0:1));
 }
 mvif->link_conf[2]=NULL;mutex_held=1;
 assert(mt792x_vif_to_link(mvif,2)==&mvif->bss_conf);
 assert(mt792x_vif_to_link(mvif,16)==&mvif->bss_conf);
 vif.mld=false;assert(mt792x_vif_to_link(mvif,1)==&mvif->bss_conf);vif.mld=true;
 rcu_held=1;
 REMOVAL
 assert(mvif->link_conf[1]==NULL);
 assert(dynamic.live==FIXED);assert(sta.live==FIXED);assert(mvif->sta.link[1]==NULL);
 if(FIXED) {assert(pending_count==2);assert(pending[0]==&dynamic&&pending[1]==&sta);rcu_held=0;dynamic.live=0;sta.live=0;assert(!dynamic.live&&!sta.live);}
 dynamic.live=sta.live=1;pending_count=0;
 mconfs[1]=mconf;mlinks[1]=mlink;sta.wcid.idx=3;d.mt76.wcid[3]=&sta.wcid;
 mvif->link_conf[1]=mconf;mvif->sta.link[1]=mlink;rcu_held=1;
 CLEANUP
 assert(mvif->link_conf[1]==NULL&&mvif->sta.link[1]==NULL);
 assert(dynamic.live==FIXED&&sta.live==FIXED);
 assert((d.mt76.wcid[3]==NULL)==FIXED);
 if(FIXED) assert(pending_count==2&&cleanups==1);
 if(FIXED) {
  struct mt76_wcid unrelated={0};
  pending_count=cleanups=0;sta.wcid.idx=0;d.mt76.wcid[0]=&unrelated;
  CLEANUP
  assert(d.mt76.wcid[0]==&unrelated&&cleanups==0&&pending_count==2);
  pending_count=0;sta.wcid.idx=17;
  CLEANUP
  assert(d.mt76.wcid[0]==&unrelated&&cleanups==0&&pending_count==2);
 }
 puts(FIXED?"fixed: RCU/WIPHY/mutex readers accepted, unlocked readers rejected, free deferred PASS":"old: three observed predicate failures and immediate reader lifetime failure reproduced PASS");
}
'''.replace('REMOVAL',removal).replace('CLEANUP',cleanup)
 with tempfile.TemporaryDirectory() as td:
  c=Path(td)/'case.c';exe=Path(td)/'case';c.write_text(PRE+helpers+'\n#define FIXED '+str(fixed)+'\n'+body)
  subprocess.run(['cc','-std=gnu11','-Wall','-Wextra','-Werror','-Wno-parentheses','-fsanitize=address,undefined',str(c),'-o',str(exe)],check=True)
  subprocess.run([str(exe)],check=True)
if len(sys.argv)>1:
 tree=Path(sys.argv[1])/'drivers/net/wireless/mediatek/mt76'
 run(tree,1)
else:
 run(R/'original/mt76',0)
 run(R/'source/drivers/net/wireless/mediatek/mt76',1)
