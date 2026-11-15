#!/usr/bin/env python3
"""Compile and exercise the MT7925 MLD TLV function from KERNEL_SOURCE."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import shlex
import tempfile

REL = Path('drivers/net/wireless/mediatek/mt76/mt7925')

def extract(text, name):
    start = text.index('static void\n' + name + '(')
    opening = text.index('{', start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (text[cursor] == '{') - (text[cursor] == '}')
        cursor += 1
    return text[start:cursor]

STUBS = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8;
typedef uint16_t __le16;
#define __packed __attribute__((packed))
#define ETH_ALEN 6
#define IEEE80211_LINK_UNSPECIFIED 15
#define IEEE80211_MLD_MAX_NUM_LINKS 15
#define STA_REC_MLD 0x20
#define BIT(x) (1UL << (x))
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define cpu_to_le16(x) (x)
#define for_each_set_bit(i, p, n) for ((i) = 0; (i) < (n); ++(i)) if (*(p) & BIT(i))
#define lockdep_is_held(p) ((void)(p), 1)
#define rcu_dereference_protected(p, c) ((void)(c), (p))
#define dev_warn_ratelimited(dev, ...) ((void)(dev), ++warnings)
struct mt792x_link_sta { struct { uint16_t idx; u8 link_id; } wcid; };
struct mt792x_sta {
    struct mt792x_link_sta deflink;
    u8 deflink_id;
    unsigned long valid_links;
    struct mt792x_link_sta *link[15];
};
struct mt792x_bss_conf { struct { u8 idx; } mt76; };
struct mt792x_dev { struct { void *dev; int mutex; } mt76; };
struct mt792x_phy { struct mt792x_dev *dev; };
struct mt792x_vif { struct mt792x_phy *phy; struct mt792x_bss_conf *link_conf[15]; };
struct ieee80211_vif { void *drv_priv; };
struct ieee80211_sta { void *drv_priv; u8 addr[6]; };
struct tlv { uint16_t tag, len; };
static unsigned warnings;
static struct mt792x_bss_conf *mt792x_vif_to_link(struct mt792x_vif *v, u8 id)
{ return v->link_conf[id]; }
static __attribute__((unused)) struct mt792x_link_sta *mt792x_sta_to_link(struct mt792x_sta *s, u8 id)
{ return s->link[id]; }
'''

HARNESS = r'''
struct sk_buff { struct sta_rec_mld out; unsigned allocated; };
static struct tlv *mt76_connac_mcu_add_tlv(struct sk_buff *b, unsigned tag, unsigned size)
{
    assert(size == sizeof(b->out));
    memset(&b->out, 0, sizeof(b->out));
    b->out.tag = tag;
    b->allocated++;
    return (struct tlv *)&b->out;
}
'''

CASES = r'''
struct fixture {
    struct mt792x_dev dev;
    struct mt792x_phy phy;
    struct mt792x_vif mvif;
    struct ieee80211_vif vif;
    struct mt792x_sta msta;
    struct ieee80211_sta sta;
    struct mt792x_bss_conf conf[15];
    struct mt792x_link_sta secondary, tertiary;
};
static void setup(struct fixture *f)
{
    memset(f, 0, sizeof(*f));
    f->phy.dev = &f->dev; f->mvif.phy = &f->phy;
    f->vif.drv_priv = &f->mvif; f->sta.drv_priv = &f->msta;
    f->msta.deflink.wcid.idx = 40; f->msta.deflink.wcid.link_id = 0;
    f->msta.deflink_id = 0; f->msta.valid_links = BIT(0);
    f->msta.link[0] = &f->msta.deflink;
    for (unsigned i = 0; i < 15; ++i) f->conf[i].mt76.idx = 10 + i;
    f->mvif.link_conf[0] = &f->conf[0];
    f->secondary.wcid.idx = 41; f->secondary.wcid.link_id = 2;
    f->tertiary.wcid.idx = 42; f->tertiary.wcid.link_id = 3;
}
static struct sk_buff encode(struct fixture *f, struct mt792x_link_sta *subject,
                             struct mt792x_bss_conf *conf,
                             struct mt792x_link_sta *pending)
{
    struct sk_buff b = {0};
#if FIXED
    mt7925_mcu_sta_mld_tlv(&b, &f->vif, &f->sta, conf, subject, pending);
#else
    (void)pending;
    mt7925_mcu_sta_mld_tlv(&b, &f->vif, &f->sta, conf, subject);
#endif
    return b;
}
static int pending_consistency(void)
{
    struct fixture f; setup(&f);
    f.mvif.link_conf[2] = &f.conf[2];
    struct sk_buff p = encode(&f, &f.msta.deflink, &f.conf[0], &f.secondary);
    struct sk_buff s = encode(&f, &f.secondary, &f.conf[2], &f.secondary);
    if (p.out.link_num != 2 || s.out.link_num != 2 ||
        memcmp(&p.out, &s.out, sizeof(p.out))) {
        fprintf(stderr, "FAIL pending primary/secondary membership: n=%u/%u\n",
                p.out.link_num, s.out.link_num);
        return 1;
    }
    assert(p.out.link[0].wlan_id == 40 && p.out.link[1].wlan_id == 41);
    assert(p.out.link[1].bss_idx == 12 && p.out.secondary_id == 41);
    assert(f.msta.valid_links == BIT(0) && f.msta.link[2] == NULL);
    return 0;
}
static void controls(void)
{
    struct fixture f; struct sk_buff b; setup(&f);
    b = encode(&f, &f.msta.deflink, &f.conf[0], NULL);
    assert(b.out.link_num == 1 && b.out.primary_id == 40);
    f.msta.valid_links |= BIT(2); f.msta.link[2] = &f.secondary;
    f.mvif.link_conf[2] = &f.conf[2];
    b = encode(&f, &f.msta.deflink, &f.conf[0], NULL);
    assert(b.out.link_num == 2 && b.out.link[1].wlan_id == 41);
    b = encode(&f, &f.secondary, &f.conf[2], &f.secondary);
    assert(b.out.link_num == 2); /* Already-published pending must not duplicate. */
    f.msta.link[2] = NULL;
    b = encode(&f, &f.msta.deflink, &f.conf[0], NULL);
    assert(b.out.link_num == 1);
    f.msta.link[2] = &f.secondary; f.mvif.link_conf[2] = NULL;
    b = encode(&f, &f.msta.deflink, &f.conf[0], &f.secondary);
    assert(b.out.link_num == 1);
    f.mvif.link_conf[2] = &f.conf[2];
    f.msta.valid_links |= BIT(3); f.msta.link[3] = &f.tertiary;
    f.mvif.link_conf[3] = &f.conf[3];
    b = encode(&f, &f.msta.deflink, &f.conf[0], NULL);
    assert(b.out.link_num == ARRAY_SIZE(b.out.link));
    assert(b.out.link[0].wlan_id == 40 && b.out.link[1].wlan_id == 41);
    setup(&f); f.msta.deflink_id = IEEE80211_LINK_UNSPECIFIED;
    b = encode(&f, &f.msta.deflink, &f.conf[0], &f.msta.deflink);
    assert(b.out.link_num == 1); /* Initial primary still uses caller's BSS. */
    unsigned old = warnings;
    b = encode(&f, &f.secondary, NULL, &f.secondary);
    assert(b.allocated == 0 && warnings == old + 1);
}
int main(void)
{
    int failed = pending_consistency();
    if (failed) return failed;
    controls();
    puts("PASS actual MLD TLV: pending consistency, publication, absent station/BSS, capacity, primary fallback");
    return 0;
}
'''

def exercise(tree, work):
    source = (tree / REL / 'mcu.c').read_text()
    header = (tree / REL / 'mcu.h').read_text()
    function = extract(source, 'mt7925_mcu_sta_mld_tlv')
    fixed = 'struct mt792x_link_sta *pending)' in function
    match = re.search(r'struct sta_rec_mld \{.*?\n\} __packed;', header, re.S)
    if match is None:
        raise RuntimeError('MT7925 firmware MLD structure not found in mcu.h')
    output = work / 'mld.c'
    output.write_text(STUBS + match.group() + '\n' + HARNESS + function + '\n' + CASES)
    binary = work / 'mld'
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    subprocess.run(compiler + ['-std=gnu11', '-Wall', '-Wextra', '-Werror', '-g', '-O1',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                    '-DFIXED=' + str(int(fixed)), str(output), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True,
                            env=os.environ | {'ASAN_OPTIONS': 'detect_leaks=1'})
    print(result.stdout + result.stderr, end='')
    return fixed, result


def check_callers(tree):
    main_source = (tree / REL / 'main.c').read_text()
    start = main_source.index('static int mt7925_mac_link_sta_add(')
    end = main_source.index('\nstatic ', start + 1)
    block = main_source[start:end]
    if len(re.findall(r'MT76_STA_INFO_STATE_ASSOC, mlink\)', block)) != 2:
        raise RuntimeError('Both add-time ASSOC updates must pass the same pending link')
    print('PASS both production add-time ASSOC callers pass the same pending link')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_source', type=Path, metavar='KERNEL_SOURCE')
    parser.add_argument('--expect-failure', action='store_true',
                        help='verify the original n=1/n=2 regression on an unpatched tree')
    args = parser.parse_args()
    tree = args.kernel_source.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='mt7925-mld-test-') as temporary:
        fixed, result = exercise(tree, Path(temporary))
    if args.expect_failure:
        if fixed or result.returncode != 1 or 'FAIL pending primary/secondary membership: n=1/2' not in result.stderr:
            raise RuntimeError('Expected the baseline membership failure, not a compiler/sanitizer error')
        print('PASS baseline regression reproduced (n=1/n=2)')
    else:
        if not fixed or result.returncode != 0:
            raise RuntimeError('Patched production MLD function did not pass')
        check_callers(tree)


if __name__ == '__main__':
    main()
