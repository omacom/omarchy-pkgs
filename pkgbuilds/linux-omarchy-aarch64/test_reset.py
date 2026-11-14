#!/usr/bin/env python3
"""Exercise production MT7925/27/28 reset NAPI selection with real DMA layouts.

Hardware/firmware operations are stubbed; queue allocation and NAPI lifecycle
are instrumented. This does not test firmware, DMA transfers or physical sleep.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


def block(text, start):
    pos = text.index(start)
    brace = text.index('{', pos)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[pos:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_source', type=Path)
    args = parser.parse_args()
    mt = args.kernel_source.resolve() / 'drivers/net/wireless/mediatek/mt76'
    pci = (mt / 'mt7925/pci.c').read_text()
    types = (mt / 'mt792x.h').read_text()
    header = (mt / 'mt7925/mt7925.h').read_text()
    declarations = '\n'.join(block(types, 'struct ' + name + ' {') + ';' for name in
                             ['mt792x_irq_map', 'mt792x_dma_ring', 'mt792x_dma_layout'])
    constants = '\n'.join(re.findall(r'^#define MT792[58]_\w*RING_SIZE\s+[^\n]+', header, re.M))
    constants += '\n' + '\n'.join(block(header, 'enum ' + name) + ';' for name in
                                    ['mt7925_txq_id', 'mt7925_rxq_id', 'mt7927_txq_id',
                                     'mt7927_rxq_id', 'mt7928_rxq_id'])
    maps = '\n'.join(block(pci, 'static const struct mt792x_irq_map ' + chip + '_irq_map') + ';'
                     for chip in ['mt7925', 'mt7927', 'mt7928'])
    layouts = '\n'.join(block(pci, 'static const struct mt792x_dma_layout ' + chip + '_dma_layout') + ';'
                        for chip in ['mt7925', 'mt7927', 'mt7928'])
    functions = '\n'.join([
        block((mt / 'mt792x_dma.c').read_text(), 'int mt792x_dma_alloc_queues('),
        block(pci, 'static int mt7927_dma_init('),
        block(pci, 'static int mt7925_dma_init('),
        block((mt / 'mt7925/pci_mac.c').read_text(), 'int mt7925e_mac_reset('),
    ])
    instrumented = {'mt76_queue_alloc', 'mt76_init_queues', 'netif_napi_add_tx',
                    'napi_disable', 'napi_enable', 'napi_schedule', 'is_mt7927', 'is_mt7928',
                    'mt76_for_each_q_rx', 'mt792x_dma_alloc_queues', 'mt7927_dma_init',
                    'mt7925_dma_init', 'mt7925e_mac_reset', 'if', 'for'}
    calls = set(re.findall(r'\b([a-z_][a-z_0-9]*)\(', functions)) - instrumented
    source = STUBS + constants + '\n' + declarations + '\n' + maps + '\n' + layouts
    source += '\n' + '\n'.join('#define ' + name + '(...) 0' for name in sorted(calls))
    source += '\n' + functions + CASES
    with tempfile.TemporaryDirectory(prefix='mt7925-reset-') as directory:
        target = Path(directory) / 'reset'
        target.with_suffix('.c').write_text(source)
        command = shlex.split(os.environ.get('CC', 'cc'))
        command += ['-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-value',
                    '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                    '-fno-omit-frame-pointer', '-g', '-I' + str(mt),
                    str(target.with_suffix('.c')), '-o', str(target)]
        subprocess.run(command, check=True)
        subprocess.run([str(target)], check=True)


STUBS = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
#define BIT(n) (1U << (n))
#define GENMASK(h,l) ((~0U << (l)) & (~0U >> (31-(h))))
#include "mt7925/regs.h"
enum { MT_RXQ_MAIN, MT_RXQ_MCU, MT_RXQ_MCU_WA, N_RX };
struct napi_struct { void *dev; bool enabled; unsigned disabled, enabled_count, scheduled; };
struct queue { int ndesc; };
struct mt76_dev { struct napi_struct napi[N_RX], tx_napi; struct queue q_rx[N_RX]; int chip; };
struct mt792x_dev { const struct mt792x_irq_map *irq_map; struct mt76_dev mt76; bool fw_assert; };
#define is_mt7927(d) ((d)->chip == 7927)
#define is_mt7928(d) ((d)->chip == 7928)
static void napi_disable(struct napi_struct *n) {
    if (!n->dev || !n->enabled) { fputs("invalid napi_disable: unregistered/disabled NAPI\n", stderr); exit(42); }
    n->enabled = false; n->disabled++;
}
static void napi_enable(struct napi_struct *n) {
    if (!n->dev || n->enabled) exit(43);
    n->enabled = true; n->enabled_count++;
}
static void napi_schedule(struct napi_struct *n) {
    if (!n->dev || !n->enabled) exit(44);
    n->scheduled++;
}
#define mt792x_dma_ring(q,n,r) { .qid=(q), .n_desc=(n), .ring_base=(r) }
#define mt76_for_each_q_rx(dev,i) for ((i)=0;(i)<N_RX;(i)++) if ((dev)->q_rx[i].ndesc)
#define mt76_queue_alloc(d,q,id,n,size,base) ((void)(d), (q)->ndesc=(n), 0)
#define netif_napi_add_tx(d,n,poll) ((n)->dev=(n))
static int register_queues(struct mt792x_dev *d) {
    for (int i=0; i<N_RX; i++) if (d->mt76.q_rx[i].ndesc) {
        d->mt76.napi[i].dev=d; napi_enable(&d->mt76.napi[i]);
    }
    return 0;
}
#define mt76_init_queues(d,poll) register_queues(d)
'''

CASES = r'''
static void check_napi(struct napi_struct *n, bool registered) {
    if (!!n->dev != registered || n->enabled != registered ||
        n->disabled != (unsigned)registered || n->scheduled != (unsigned)registered ||
        n->enabled_count != 2*(unsigned)registered) exit(46);
}
int main(void) {
    const struct mt792x_irq_map *maps[] = {&mt7925_irq_map, &mt7927_irq_map, &mt7928_irq_map};
    const int chips[] = {7925, 7927, 7928};
    for (unsigned c=0; c<sizeof(chips)/sizeof(chips[0]); c++) {
        struct mt792x_dev d = { .irq_map=maps[c], .mt76={.chip=chips[c]} };
        if ((chips[c] == 7927 ? mt7927_dma_init(&d) : mt7925_dma_init(&d))) return 45;
        if (mt7925e_mac_reset(&d)) return 45;
        for (int i=0; i<N_RX; i++) check_napi(&d.mt76.napi[i], d.mt76.q_rx[i].ndesc != 0);
        check_napi(&d.mt76.tx_napi, true);
        if (!!d.mt76.napi[MT_RXQ_MCU_WA].dev != (chips[c] != 7925)) return 47;
        if (maps[c]->rx.all_complete_mask != (maps[c]->rx.data_complete_mask |
            maps[c]->rx.wm_complete_mask | maps[c]->rx.wm2_complete_mask)) return 48;
        printf("PASS MT%d: production allocation/reset NAPI lifecycle and RX mask coherent\n", chips[c]);
    }
}
'''

if __name__ == '__main__':
    main()
