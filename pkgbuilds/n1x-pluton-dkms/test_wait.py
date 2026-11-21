"""Compile the production wait function with deterministic clock/MMIO shims."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
source = (ROOT / "n1x_pluton.c").read_text()
start = source.index("static int n1x_rot_wait(")
end = source.index("\nstatic int ", start + 1)
function = source[start:end]

HARNESS = r"""
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
typedef uint32_t u32;
struct n1x_pluton { u32 status; };
static unsigned long tick, step, budget;
static unsigned int clock_reads, polls;
static unsigned long clock_read(void)
{
    unsigned long value = tick;
    tick += step;
    clock_reads++;
    return value;
}
#define jiffies clock_read()
/* Equivalent unsigned-long wrap ordering, without signed-overflow UB. */
#define time_after_eq(a, b) (((unsigned long)(a) - (unsigned long)(b)) <= LONG_MAX)
#define jiffies_to_usecs(value) ((value) * 1000UL)
#define BIT(n) (1U << (n))
static u32 *n1x_rot_reg(struct n1x_pluton *p, unsigned int reg)
{
    assert(reg == 0x20);
    return &p->status;
}
/* Model the poll boundary: zero disables timeout in the kernel. Return a
 * distinct sentinel instead of hanging this offline regression test. */
#define readl_poll_timeout(addr, value, condition, sleep, timeout) \
    ({ \
        budget = (timeout); \
        polls++; \
        assert((sleep) == 1000); \
        (value) = *(addr); \
        (condition) ? 0 : (budget ? -ETIMEDOUT : -EINPROGRESS); \
    })
"""

CASES = r"""
static void check(unsigned long now, unsigned long advance,
                  unsigned long deadline, u32 status, int expected,
                  unsigned long expected_budget, unsigned int expected_polls)
{
    struct n1x_pluton p = { .status = status };
    tick = now;
    step = advance;
    budget = 0;
    clock_reads = polls = 0;
    assert(n1x_rot_wait(&p, 0x20, deadline) == expected);
    assert(budget == expected_budget);
    assert(polls == expected_polls);
    assert(clock_reads == 1);
}
int main(void)
{
    /* The old second clock read reaches/passes the deadline here. */
    check(99, 1, 100, 0, -ETIMEDOUT, 1000, 1);
    check(99, 2, 100, 0, -ETIMEDOUT, 1000, 1);
    check(100, 1, 100, 1, -ETIMEDOUT, 0, 0);
    check(101, 1, 100, 1, -ETIMEDOUT, 0, 0);
    check(90, 0, 100, 1, 0, 10000, 1);
    check(90, 0, 100, 0, -ETIMEDOUT, 10000, 1);
    check(ULONG_MAX - 1, 2, 1, 1, 0, 3000, 1);
    check(ULONG_MAX, 1, 0, 0, -ETIMEDOUT, 1000, 1);
    check(0, 1, ULONG_MAX, 1, -ETIMEDOUT, 0, 0);
    puts("production wait: 9 deterministic deadline cases passed");
    return 0;
}
"""

with tempfile.TemporaryDirectory(prefix="n1x-pluton-wait-") as directory:
    path = Path(directory)
    (path / "wait_test.c").write_text(HARNESS + function + CASES)
    subprocess.run(
        shlex.split(os.environ.get("CC", "cc"))
        + ["-std=gnu11", "-Wall", "-Wextra", "-Werror",
           "-fsanitize=address,undefined", "-g", str(path / "wait_test.c"),
           "-o", str(path / "wait-test")],
        check=True,
    )
    subprocess.run([str(path / "wait-test")], check=True)
