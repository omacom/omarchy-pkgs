#!/usr/bin/env python3
"""Compile and test iwl_poll_prph_bit from a prepared Linux source tree.

Usage: python tests/iwlwifi-prph-poll.py path/to/linux/drivers/net/wireless/intel/iwlwifi/iwl-io.c
The mocked transport checks access failures, lock pairing, real register values,
and the existing timeout/retry behavior. No driver is loaded or device touched.
"""
import pathlib
import re
import resource
import subprocess
import sys
import tempfile

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'^int iwl_poll_prph_bit\([^\n]*\n.*?^\}', source, re.M | re.S)
if not match:
    raise SystemExit('iwl_poll_prph_bit not found')
header = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
typedef uint32_t u32;
struct iwl_trans { int unused; };
#define IWL_POLL_INTERVAL 10
static int attempts, reads, releases, delays, lock_held;
static int fail_at, ready_at;
static u32 register_value;
static bool iwl_trans_grab_nic_access(struct iwl_trans *t)
{
    (void)t;
    assert(!lock_held);
    attempts++;
    if (attempts == fail_at) return false;
    lock_held = 1;
    return true;
}
static void iwl_trans_release_nic_access(struct iwl_trans *t)
{
    (void)t;
    assert(lock_held);
    lock_held = 0;
    releases++;
}
static u32 iwl_read_prph_no_grab(struct iwl_trans *t, u32 addr)
{
    (void)t; (void)addr;
    assert(lock_held);
    reads++;
    return ready_at && reads >= ready_at ? register_value : 0;
}
static u32 __attribute__((unused)) iwl_read_prph(struct iwl_trans *t, u32 addr)
{
    if (!iwl_trans_grab_nic_access(t)) return 0x5a5a5a5a;
    u32 value = iwl_read_prph_no_grab(t, addr);
    iwl_trans_release_nic_access(t);
    return value;
}
static void udelay(int us) { assert(!lock_held); assert(us == 10); delays++; }
static void reset(void)
{
    attempts = reads = releases = delays = lock_held = 0;
    fail_at = ready_at = 0;
    register_value = 1;
}
'''
main = r'''
int main(void)
{
    struct iwl_trans trans = {0};
    /* Inaccessible hardware: abort one failed access, without reading/releasing. */
    reset(); fail_at = 1;
    assert(iwl_poll_prph_bit(&trans, 0, 1, 1, 1000) == -ETIMEDOUT);
    assert(attempts == 1 && reads == 0 && releases == 0 && delays == 0);
    /* The old failure placeholder must never be mistaken for a matching value. */
    reset(); fail_at = 1;
    assert(iwl_poll_prph_bit(&trans, 0, 0x5a5a5a5a, ~0U, 1000) == -ETIMEDOUT);
    assert(attempts == 1 && reads == 0 && releases == 0);
    /* Immediately ready hardware. */
    reset(); ready_at = 1;
    assert(iwl_poll_prph_bit(&trans, 0, 1, 1, 1000) == 0);
    assert(attempts == 1 && reads == 1 && releases == 1 && delays == 0);
    /* Preserve retries and masks while register access works. */
    reset(); ready_at = 3; register_value = 0x81;
    assert(iwl_poll_prph_bit(&trans, 0, 1, 1, 1000) == 0);
    assert(attempts == 3 && reads == 3 && releases == 3 && delays == 2);
    /* Loss of access after a nonmatching read must abort without another delay. */
    reset(); fail_at = 2;
    assert(iwl_poll_prph_bit(&trans, 0, 1, 1, 1000) == -ETIMEDOUT);
    assert(attempts == 2 && reads == 1 && releases == 1 && delays == 1);
    /* An accessible but never-ready device keeps its existing polling budget. */
    reset();
    assert(iwl_poll_prph_bit(&trans, 0, 1, 1, 1000) == -ETIMEDOUT);
    assert(attempts == 100 && reads == 100 && releases == 100 && delays == 100);
    assert(!lock_held);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory)
    (path / 'poll.c').write_text(header + match.group() + main)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', str(path / 'poll.c'), '-o', str(path / 'poll')], check=True)
    subprocess.run([str(path / 'poll')], check=True)
print('PASS: six peripheral-register polling cases')
