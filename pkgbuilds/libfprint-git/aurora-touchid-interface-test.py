# SPDX-License-Identifier: MIT
# From aurora-silicon/aurora-sep-userspace 12f26f61, libfprint/test_interface.py
# (Ryan Murray), renamed for this driver's aurora-bio.h: SEP_BIO_* reads
# AURORA_BIO_*, sep_bio_* reads aurora_bio_*.
"""Compile the patched driver's version and enrolment paths with fake ioctls."""
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def function(source, name):
    match = re.search(r'^' + name + r' \(', source, re.M)
    if match is None:
        raise AssertionError(f'missing {name}')
    opening = source.index('{', match.start())
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return 'static gboolean\n' + source[match.start():end]


HARNESS = r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include "aurora-bio.h"
typedef int gboolean;
typedef uint32_t guint32;
typedef uint8_t guint8;
typedef int GError;
typedef struct { guint32 iface_version; } FpiDeviceAurora;
#define FALSE 0
#define FP_DEVICE_ERROR 1
#define FP_DEVICE_ERROR_NOT_SUPPORTED 2
static void g_set_error_literal(GError **error, int domain, int code, const char *message)
{ (void)domain; (void)message; *error = (GError *)(uintptr_t)code; }
static unsigned int calls;
static unsigned long requests[2];
static unsigned int fail_call;
static const GError failure = 99;
static struct aurora_bio_enrol_start expected;
@LEGACY@
_Static_assert(sizeof(struct aurora_bio_info) == 32, "info ABI");
_Static_assert(sizeof(struct aurora_enrol_start_v4) == 136, "v4 enrol ABI");
_Static_assert(sizeof(struct aurora_bio_enrol_start) == 144, "v5 enrol ABI");
_Static_assert(_IOC_SIZE(AURORA_ENROL_START_V4) == 136, "v4 ioctl size");
_Static_assert(_IOC_SIZE(AURORA_BIO_ENROL_START) == 144, "v5 ioctl size");
_Static_assert(AURORA_ENROL_START_V4 != AURORA_BIO_ENROL_START, "distinct ioctls");
static gboolean aurora_ioctl(FpiDeviceAurora *self, unsigned long req, void *arg, GError **error)
{
    assert(calls < 2);
    requests[calls++] = req;
    if (self->iface_version == 4) {
        struct aurora_enrol_start_v4 *legacy = arg;
        assert(req == AURORA_ENROL_START_V4);
        assert(legacy->flags == expected.flags && legacy->reserved == 0);
        assert(memcmp(legacy->label, expected.label, AURORA_BIO_LABEL_LEN) == 0);
    } else {
        assert(req == (calls == 1 ? AURORA_BIO_PREPARE_ENROL : AURORA_BIO_ENROL_START));
        assert(memcmp(arg, &expected, sizeof expected) == 0);
    }
    if (calls == fail_call) { *error = (GError *)&failure; return 0; }
    return 1;
}
@SUPPORTED@
@START@
int main(void)
{
    for (unsigned int v = 0; v < 8; v++)
        assert(aurora_iface_supported(v) == (v == 4 || v == 5));
    memset(expected.label, 0xa5, sizeof expected.label);
    expected.flags = 0; expected.account_uid = 1000; expected.finger = 7;
    for (unsigned int version = 0; version < 8; version++) {
        for (fail_call = 0; fail_call < 3; fail_call++) {
            FpiDeviceAurora self = { version };
            GError *error = NULL;
            calls = 0;
            gboolean ok = aurora_start_enrol(&self, &expected, &error);
            if (version == 4) {
                assert(calls == 1 && ok == (fail_call != 1));
            } else if (version == 5) {
                assert(calls == (fail_call == 1 ? 1 : 2));
                assert(ok == (fail_call == 0));
            } else {
                assert(!ok && calls == 0 && error != NULL);
            }
            if ((version == 4 && fail_call == 1) ||
                (version == 5 && fail_call != 0))
                assert(error == &failure);
        }
    }
    return 0;
}
'''


def main():
    source = Path(sys.argv[1]).read_text()
    header = Path(sys.argv[2]).resolve()
    legacy = source[source.index('struct aurora_enrol_start_v4 {'):source.index('static gboolean\naurora_start_enrol')]
    code = HARNESS.replace('@LEGACY@', legacy).replace('@SUPPORTED@', function(source, 'aurora_iface_supported')).replace('@START@', function(source, 'aurora_start_enrol'))
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        (path / 'test.c').write_text(code)
        subprocess.run(['cc', '-std=c11', '-Wall', '-Werror', '-I' + str(header.parent), 'test.c', '-o', 'test'], cwd=path, check=True)
        subprocess.run([str(path / 'test')], check=True)


if __name__ == '__main__':
    main()
