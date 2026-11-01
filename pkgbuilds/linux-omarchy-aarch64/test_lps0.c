/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

typedef uint64_t u64;
typedef int guid_t;
#define GUID_INIT(...) 0
#define BIT_ULL(n) (1ULL << (n))
#define ACPI_HANDLE(dev) (dev)
#define ACPI_FREE(obj) free(obj)
#define GFP_KERNEL 0
#define PWRAP_PLID_MT8901 2
#define PM_SUSPEND_TO_IDLE 1
#define PM_SUSPEND_MEM 3
#define dev_info(...) ((void)0)
#define dev_warn(...) ((void)0)
#define dev_err(...) ((void)0)
struct pwrap_driver_data;
struct device { struct pwrap_driver_data *priv; };
struct pwrap_lps0;
struct pwrap_driver_data { struct device *dev; u64 plid; struct pwrap_lps0 *lps0; };
union acpi_object { int dummy; };
struct dev_pm_ops {
 int (*suspend_late)(struct device *);
 int (*resume_early)(struct device *);
 void (*complete)(struct device *);
 int (*suspend_noirq)(struct device *);
 int (*resume_noirq)(struct device *);
};
static int pm_suspend_target_state;
static bool gate;
static unsigned int calls[512], count, sleeps, fail_function;
static unsigned int fail_count;
static unsigned int fail_second_function, fail_second_count;
static u64 advertised;
static void *dev_get_drvdata(struct device *dev) { return dev->priv; }
static bool acpi_processor_n1x_s2idle_active(void) { return gate; }
static void msleep(unsigned int ms) { assert(ms == 3000); sleeps++; }
static void *devm_kzalloc(struct device *dev, size_t size, int flags)
{ (void)dev; (void)flags; return calloc(1, size); }
static bool acpi_check_dsm(struct device *dev, const guid_t *guid, int rev, u64 mask)
{ (void)dev; (void)guid; (void)rev; return (advertised & mask) == mask; }
static union acpi_object *acpi_evaluate_dsm(struct device *dev, const guid_t *guid,
                                         int rev, unsigned int fn, void *arg)
{
 (void)dev; (void)guid; (void)rev; (void)arg;
 assert(count < sizeof(calls) / sizeof(calls[0]));
 calls[count++] = fn;
 if (fn == fail_function && fail_count) { fail_count--; return NULL; }
 if (fn == fail_second_function && fail_second_count) {
  fail_second_count--; return NULL;
 }
 union acpi_object *obj = malloc(sizeof(*obj));
 assert(obj);
 return obj;
}
#include "lps0-under-test.c"
static struct device dev;
static struct pwrap_driver_data priv;
static void reset(void)
{
 free(priv.lps0);
 priv = (struct pwrap_driver_data){ .dev = &dev, .plid = 2 };
 dev.priv = &priv;
 advertised = 0x3f8;
 count = sleeps = fail_function = fail_count = 0;
 fail_second_function = fail_second_count = 0;
 gate = true;
 pm_suspend_target_state = PM_SUSPEND_TO_IDLE;
 assert(pwrap_lps0_init(&priv) == 0);
 assert(priv.lps0);
}
static void expect(const unsigned int *seq, unsigned int len)
{
 assert(count == len);
 for (unsigned int i = 0; i < len; ++i) assert(calls[i] == seq[i]);
}
#define EXPECT(...) do { const unsigned int seq[] = { __VA_ARGS__ }; expect(seq, sizeof(seq)/sizeof(seq[0])); } while (0)
static void clean(void)
{
 assert(!priv.lps0->attempted && !priv.lps0->late_cycle);
 assert(!priv.lps0->screen_off && !priv.lps0->ms_entered);
 assert(!priv.lps0->lps0_entered && !priv.lps0->display_pending);
}
int main(void)
{
 /* Successful late/noirq/early/complete sequence over repeated cycles. */
 reset();
 for (unsigned int cycle = 0; cycle < 20; ++cycle) {
  count = 0;
  assert(pwrap_lps0_pm_ops.suspend_late(&dev) == 0);
  assert(pwrap_lps0_pm_ops.suspend_noirq(&dev) == 0);
  assert(pwrap_lps0_pm_ops.resume_noirq(&dev) == 0);
  assert(pwrap_lps0_pm_ops.resume_early(&dev) == 0);
  pwrap_lps0_pm_ops.complete(&dev);
  EXPECT(3,7,5,6,9,8,4);
  clean();
 }
 assert(sleeps == 20);
 /* A failure at every entry stage unwinds before returning; no settle. */
 const unsigned int entry[] = {3,7,5};
 for (unsigned int i = 0; i < 3; ++i) {
  reset(); fail_function = entry[i]; fail_count = 1;
  assert(pwrap_lps0_pm_ops.suspend_late(&dev) == -EIO);
  pwrap_lps0_pm_ops.complete(&dev);
  assert(!sleeps); clean();
  if (i == 0) { EXPECT(3,9,4); }
  if (i == 1) { EXPECT(3,7,9,8,4); }
  if (i == 2) { EXPECT(3,7,5,6,9,8,4); }
 }
 /* Each failed exit stays pending and complete retries only that exit. */
 const unsigned int exits[] = {6,9,8,4};
 for (unsigned int i = 0; i < 4; ++i) {
  reset(); assert(pwrap_lps0_pm_ops.suspend_late(&dev) == 0);
  fail_function = exits[i]; fail_count = 1;
  assert(pwrap_lps0_pm_ops.resume_early(&dev) == -EIO);
  assert(priv.lps0->attempted);
  pwrap_lps0_pm_ops.complete(&dev);
  assert(count == 8 && calls[7] == exits[i]); clean();
 }
 /* Failed entry plus failed unwind is retried by complete. */
 reset(); fail_function = 3; fail_count = 1;
 fail_second_function = 4; fail_second_count = 1;
 assert(pwrap_lps0_pm_ops.suspend_late(&dev) == -EIO);
 assert(priv.lps0->attempted);
 pwrap_lps0_pm_ops.complete(&dev); EXPECT(3,9,4,4); clean();
 /* Persistent restore failure blocks another prepare and retains state. */
 reset(); assert(pwrap_lps0_pm_ops.suspend_late(&dev) == 0);
 fail_function = 6; fail_count = 4;
 assert(pwrap_lps0_pm_ops.resume_early(&dev) == -EIO);
 pwrap_lps0_pm_ops.complete(&dev);
 count = 0;
 assert(pwrap_lps0_pm_ops.suspend_late(&dev) == -EIO);
 EXPECT(6);
 pwrap_lps0_pm_ops.complete(&dev);
 assert(priv.lps0->attempted);
 fail_count = 0;
 assert(pwrap_lps0_pm_ops.suspend_late(&dev) == 0);
 assert(pwrap_lps0_pm_ops.resume_early(&dev) == 0);
 pwrap_lps0_pm_ops.complete(&dev); clean();
 /* Abort after late, before early, is balanced by complete. */
 reset(); assert(pwrap_lps0_pm_ops.suspend_late(&dev) == 0);
 pwrap_lps0_pm_ops.complete(&dev); EXPECT(3,7,5,6,9,8,4); clean();
 /* No opt-in/active coordination, deep, or partial mask retains stock timing. */
 for (unsigned int i = 0; i < 4; ++i) {
  reset();
  if (i == 0) gate = false;
  if (i == 1) pm_suspend_target_state = PM_SUSPEND_MEM;
  if (i == 2) priv.lps0->functions &= ~BIT_ULL(9);
  if (i == 3) priv.plid = 1;
  assert(pwrap_lps0_pm_ops.suspend_late(&dev) == 0);
  assert(count == 0 && !sleeps);
  assert(pwrap_lps0_pm_ops.suspend_noirq(&dev) == 0);
  assert(count == 3);
  assert(pwrap_lps0_pm_ops.resume_noirq(&dev) == 0);
  assert(pwrap_lps0_pm_ops.resume_early(&dev) == 0);
  pwrap_lps0_pm_ops.complete(&dev);
  assert(count == (i == 2 ? 6U : 7U)); clean();
 }
 /* Unsupported platform / DSM does not allocate notification state. */
 reset(); free(priv.lps0); priv.lps0 = NULL; priv.plid = 1;
 assert(pwrap_lps0_init(&priv) == 0 && !priv.lps0);
 priv.plid = 2; advertised = 0;
 assert(pwrap_lps0_init(&priv) == 0 && !priv.lps0);
 assert(pwrap_lps0_pm_ops.suspend_late(&dev) == 0);
 assert(pwrap_lps0_pm_ops.resume_early(&dev) == 0);
 pwrap_lps0_pm_ops.complete(&dev);
 puts("actual LPS0 callbacks: all cases passed");
 return 0;
}
