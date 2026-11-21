/*
 * ct720-display-light — panel brightness for the MacBook Air (M1, 2020), J313.
 *
 * One ambient sensor on t8103 (Asahi t8103.dtsi node aop_als). This process
 * finds it by scanning /sys/bus/iio/devices star-slash-name for aop-sensors-als.
 * It does not assume iio:device0. in_illuminance_input is lux as a decimal
 * string (IIO_VAL_INT_PLUS_MICRO).
 *
 * macOS stores brightness in nits (CoreBrightness BrightnessLevelNits and an
 * AutoBrightnessCurve dictionary). That dictionary and the manual-change
 * behavior are undocumented. Nothing public describes learning, so a learned
 * point is off unless --learn is passed, and it is not saved.
 *
 * The lux-to-nits anchors below are guesses, not measurements and not Apple's
 * curve. nits = clamp(curve(lux) * 2^offset_stops, min 3, max 394). The panel
 * sysfs level is the shipped linux-aurora #224 CIE 1931 map
 * (dcp_perceptual_nits / dcp_level_from_nits). #225 caps this panel at 394
 * nits. This file does not write the firmware DAC table.
 *
 * ct720-kbd-light fades the keyboard when the panel drops more than 12%.
 * A slow automatic change here can cross that line. That is a follow-up for
 * the keyboard daemon, not handled in this process.
 *
 * --self-test returns before any sysfs or input open.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#include <linux/input.h>

static const char IIO_ROOT[] = "/sys/bus/iio/devices";
static const char ALS_NAME[] = "aop-sensors-als";
static const char BL_BRIGHT[] = "/sys/class/backlight/apple-panel-bl/brightness";
static const char BL_MAX[] = "/sys/class/backlight/apple-panel-bl/max_brightness";
static const char BL_ACTUAL[] = "/sys/class/backlight/apple-panel-bl/actual_brightness";
static const char BL_POWER[] = "/sys/class/backlight/apple-panel-bl/bl_power";
static const char STATE_DIR[] = "/var/lib/ct720-display-light";
static const char STATE_PATH[] = "/var/lib/ct720-display-light/state";
static const char STATE_TMP[] = "/var/lib/ct720-display-light/state.tmp";

static const double TICK_S = 0.050;
static const double LUX_EMA_TAU = 1.5;
static const double EASE_S = 3.5;
static const double MANUAL_PAUSE_S = 3.0;
static const double SETTLE_S = 0.5;
static const double SAVE_EVERY_S = 30.0;
static const double DEFAULT_MIN_NITS = 3.0;
static const double DEFAULT_MAX_NITS = 394.0;

/* Guesses. Not measurements and not Apple's AutoBrightnessCurve. */
struct nit_anchor {
	double lux;
	double nits;
};

static const struct nit_anchor ANCHORS[] = {
	{ 0.0, 8.0 },
	{ 5.0, 30.0 },
	{ 20.0, 70.0 },
	{ 50.0, 110.0 },
	{ 150.0, 170.0 },
	{ 400.0, 250.0 },
	{ 1000.0, 330.0 },
	{ 2500.0, 394.0 },
};

enum { ANCHOR_COUNT = sizeof ANCHORS / sizeof ANCHORS[0] };

enum sample_kind {
	SAMPLE_QUIET = 0,
	SAMPLE_ADOPT = 1,
	SAMPLE_MANUAL = 2
};

struct learn_point {
	int valid;
	double lux;
	double nits;
};

struct level_track {
	int last_level;
	int last_written;
	double settle_left;
};

struct config {
	int verbose;
	int dry_run;
	int no_auto;
	int learn;
	int check_sensor;
	double min_nits;
	double max_nits;
};

static volatile sig_atomic_t g_stop;
static int g_failures;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

/* --- CIE map copied from shipped linux-aurora #224 (no 4-nit floor) --- */

#define DCP_LUMINANCE_SHIFT 16
#define DCP_LUMINANCE_SCALE (1U << DCP_LUMINANCE_SHIFT)

static uint32_t dcp_cie1931(uint32_t lightness)
{
	uint64_t retval;

	lightness *= 100;
	if (lightness <= (8U * DCP_LUMINANCE_SCALE)) {
		retval = (lightness * 10U + 9033U / 2) / 9033U;
	} else {
		retval = (lightness + (16ULL * DCP_LUMINANCE_SCALE)) / 116;
		retval *= retval * retval;
		retval += 1ULL << (2 * DCP_LUMINANCE_SHIFT - 1);
		retval >>= 2 * DCP_LUMINANCE_SHIFT;
	}
	return (uint32_t)retval;
}

static uint32_t dcp_perceptual_nits(uint32_t level, uint32_t maximum)
{
	uint32_t lightness;
	uint64_t y;

	if (!maximum)
		return 0;
	if (level >= maximum)
		return maximum;

	lightness = (uint32_t)((uint64_t)level * DCP_LUMINANCE_SCALE / maximum);
	y = dcp_cie1931(lightness);
	return (uint32_t)((y * maximum + DCP_LUMINANCE_SCALE / 2) / DCP_LUMINANCE_SCALE);
}

static uint32_t dcp_level_from_nits(uint32_t nits, uint32_t maximum)
{
	uint32_t lo, hi, mid;

	if (!maximum)
		return 0;
	if (nits >= maximum)
		return maximum;

	lo = 0;
	hi = maximum;
	while (lo < hi) {
		mid = lo + (hi - lo) / 2;
		if (dcp_perceptual_nits(mid, maximum) >= nits)
			hi = mid;
		else
			lo = mid + 1;
	}
	return lo;
}

static double clamp_nits(double n, double min_nits, double max_nits)
{
	if (!(n > min_nits))
		return min_nits;
	if (n > max_nits)
		return max_nits;
	return n;
}

/*
 * Linear in lux from 0 to 5 because log(0) is undefined. Above 5, linear in
 * log lux between the guessed anchors. At and above 2500 lux the curve is 394.
 */
static double curve_nits(double lux)
{
	int i;

	if (!(lux > 0.0))
		return ANCHORS[0].nits;
	if (lux >= ANCHORS[ANCHOR_COUNT - 1].lux)
		return ANCHORS[ANCHOR_COUNT - 1].nits;
	if (lux <= ANCHORS[1].lux) {
		double t = lux / ANCHORS[1].lux;

		return ANCHORS[0].nits + t * (ANCHORS[1].nits - ANCHORS[0].nits);
	}

	for (i = 1; i < ANCHOR_COUNT - 1; i++) {
		if (lux <= ANCHORS[i + 1].lux)
			break;
	}
	if (i >= ANCHOR_COUNT - 1)
		return ANCHORS[ANCHOR_COUNT - 1].nits;

	{
		double x0 = log(ANCHORS[i].lux);
		double x1 = log(ANCHORS[i + 1].lux);
		double t = (log(lux) - x0) / (x1 - x0);

		return ANCHORS[i].nits + t * (ANCHORS[i + 1].nits - ANCHORS[i].nits);
	}
}

/* Ignore a change smaller than 10% in log lux. Equal to 10% counts. */
static int lux_change_counts(double old, double neu)
{
	if (!(old > 0.0) || !(neu > 0.0))
		return old != neu;
	return fabs(log(neu / old)) >= log(1.10);
}

/*
 * user_nits of 0 cannot be a log2 ratio. Treat it as the floor so the stored
 * offset still round-trips through the clamp instead of becoming -inf.
 */
static double offset_stops_from(double user_nits, double curve, double min_nits)
{
	double n = user_nits;

	if (!(curve > 0.0))
		return 0.0;
	if (!(n > 0.0) || n < min_nits)
		n = min_nits;
	return log2(n / curve);
}

static double apply_stops(double curve, double stops, double min_nits, double max_nits)
{
	return clamp_nits(curve * exp2(stops), min_nits, max_nits);
}

static int learn_applies(int learn, const struct learn_point *pt, double lux)
{
	if (!learn || !pt || !pt->valid)
		return 0;
	if (!(lux > 0.0) || !(pt->lux > 0.0))
		return 0;
	return fabs(log(lux / pt->lux)) < log(1.10);
}

static double target_nits(double lux, double offset_stops, int learn,
			  const struct learn_point *pt, double min_nits, double max_nits)
{
	double n;

	if (learn_applies(learn, pt, lux))
		n = pt->nits;
	else
		n = curve_nits(lux) * exp2(offset_stops);
	return clamp_nits(n, min_nits, max_nits);
}

static int level_for_nits(double nits, int maximum)
{
	long rounded;

	if (maximum <= 0)
		return 0;
	if (!(nits > 0.0))
		return 0;
	rounded = lround(nits);
	if (rounded < 0)
		rounded = 0;
	if (rounded > maximum)
		rounded = maximum;
	return (int)dcp_level_from_nits((uint32_t)rounded, (uint32_t)maximum);
}

/*
 * Plateaus share one nit value. The panel is already there when its current
 * level shows want_nits, even if that level is above the smallest step of
 * the plateau. Do not walk it down to that step.
 */
static int needs_ramp(int current_level, double want_nits, int maximum)
{
	long want_rounded;
	uint32_t cur_nits;

	if (maximum <= 0 || current_level < 0)
		return 0;
	if (current_level > maximum)
		current_level = maximum;
	want_rounded = lround(want_nits);
	if (want_rounded < 0)
		want_rounded = 0;
	if (want_rounded > maximum)
		want_rounded = maximum;
	cur_nits = dcp_perceptual_nits((uint32_t)current_level, (uint32_t)maximum);
	return (long)cur_nits != want_rounded;
}

static double ease_nits(double from, double to, double elapsed, double duration)
{
	double t;

	if (!(duration > 0.0) || elapsed >= duration)
		return to;
	if (!(elapsed > 0.0))
		return from;
	t = elapsed / duration;
	return from + (to - from) * t;
}

/* Blanked or lid-closed time does not move the ramp. */
static double ease_elapsed(double elapsed, double dt, int writable)
{
	if (!writable || !(dt > 0.0))
		return elapsed;
	return elapsed + dt;
}

/*
 * Before the first reading, and on the tick the panel becomes writable
 * again, the hardware level is adopted. It is not a manual event. Blanking
 * often drops brightness to 0. While easing, or for SETTLE_S after our own
 * write, actual_brightness lag is not a manual event either.
 */
static int classify_actual(int writable, int was_writable, int have_sample,
			   int easing, double settle_left, int last_written, int actual)
{
	if (!writable)
		return SAMPLE_QUIET;
	if (!have_sample || !was_writable)
		return SAMPLE_ADOPT;
	if (easing || settle_left > 0.0)
		return SAMPLE_QUIET;
	if (last_written >= 0 && actual != last_written)
		return SAMPLE_MANUAL;
	return SAMPLE_QUIET;
}

/*
 * Dry-run remembers the level it would have written (last_level) and leaves
 * last_written on the real hardware baseline. It also does not start the
 * post-write settle window, because it did not write.
 */
static void note_output(struct level_track *t, int level, int dry_run)
{
	t->last_level = level;
	if (!dry_run) {
		t->last_written = level;
		t->settle_left = SETTLE_S;
	}
}

/* dpms off, lid closed, or backlight power not unblank. */
static int panel_is_writable(int dpms_off, int lid_closed, int power_known, int bl_power)
{
	if (dpms_off || lid_closed)
		return 0;
	if (power_known && bl_power != 0)
		return 0;
	return 1;
}

static int format_state(char *buf, size_t cap, double offset_stops)
{
	int n;

	if (!isfinite(offset_stops))
		return -1;
	n = snprintf(buf, cap, "offset_stops %.8f\n", offset_stops);
	if (n < 0 || (size_t)n >= cap)
		return -1;
	return 0;
}

static int parse_state(const char *text, double *offset_stops)
{
	const char *p = text;
	char *end = NULL;
	double v;

	if (!text || !offset_stops)
		return -1;
	while (*p == ' ' || *p == '\t')
		p++;
	if (strncmp(p, "offset_stops ", 13) != 0)
		return -1;
	errno = 0;
	v = strtod(p + 13, &end);
	if (end == p + 13 || errno || !isfinite(v))
		return -1;
	*offset_stops = v;
	return 0;
}

/* --- self-test: memory only, no sysfs and no input --- */

static void expect_int(const char *name, int got, int want)
{
	if (got != want) {
		fprintf(stderr, "self-test: %s: got %d want %d\n", name, got, want);
		g_failures++;
	}
}

static void expect_u32(const char *name, uint32_t got, uint32_t want)
{
	if (got != want) {
		fprintf(stderr, "self-test: %s: got %u want %u\n", name, got, want);
		g_failures++;
	}
}

static void expect_near(const char *name, double got, double want, double eps)
{
	if (!isfinite(got) || fabs(got - want) > eps) {
		fprintf(stderr, "self-test: %s: got %.8f want %.8f\n", name, got, want);
		g_failures++;
	}
}

static void test_curve(void)
{
	static const struct {
		double lux;
		double nits;
		const char *name;
	} knots[] = {
		{ 0.0, 8.0, "anchor 0" },
		{ 5.0, 30.0, "anchor 5" },
		{ 20.0, 70.0, "anchor 20" },
		{ 50.0, 110.0, "anchor 50" },
		{ 150.0, 170.0, "anchor 150" },
		{ 400.0, 250.0, "anchor 400" },
		{ 1000.0, 330.0, "anchor 1000" },
		{ 2500.0, 394.0, "anchor 2500" },
		{ 3000.0, 394.0, "anchor 3000" },
	};
	size_t i;

	for (i = 0; i < sizeof knots / sizeof knots[0]; i++)
		expect_near(knots[i].name, curve_nits(knots[i].lux), knots[i].nits, 1e-9);

	/* Geometric mean of 5 and 20. Halfway in log lux is 50 nits. */
	expect_near("lux 10", curve_nits(10.0), 50.0, 1e-6);
	/* Halfway from 0 to 5 lux, linear because log lux is undefined at 0. */
	expect_near("lux 2.5", curve_nits(2.5), 19.0, 1e-9);
}

static void test_gate(void)
{
	expect_int("1.09 ignored", lux_change_counts(1.0, 1.09), 0);
	expect_int("1.11 counts", lux_change_counts(1.0, 1.11), 1);
	expect_int("1.09 down ignored", lux_change_counts(1.09, 1.0), 0);
	expect_int("1.11 down counts", lux_change_counts(1.11, 1.0), 1);
}

static void test_offset_and_clamp(void)
{
	double stops = offset_stops_from(60.0, 30.0, DEFAULT_MIN_NITS);

	expect_near("stops", stops, 1.0, 1e-12);
	expect_near("apply round-trip",
		    apply_stops(30.0, stops, DEFAULT_MIN_NITS, DEFAULT_MAX_NITS),
		    60.0, 1e-9);
	expect_near("clamp high",
		    apply_stops(30.0, 20.0, DEFAULT_MIN_NITS, DEFAULT_MAX_NITS),
		    394.0, 1e-9);
	expect_near("clamp low",
		    apply_stops(30.0, -20.0, DEFAULT_MIN_NITS, DEFAULT_MAX_NITS),
		    3.0, 1e-9);
	expect_near("floor", clamp_nits(0.0, 3.0, 394.0), 3.0, 0.0);
	expect_near("ceiling", clamp_nits(500.0, 3.0, 394.0), 394.0, 0.0);
}

static void test_cie(void)
{
	int level;
	int plateau = 0;
	uint32_t prev = 0;
	const uint32_t maximum = 394;

	expect_u32("perceptual 0", dcp_perceptual_nits(0, maximum), 0);
	expect_u32("perceptual max", dcp_perceptual_nits(maximum, maximum), maximum);
	expect_u32("level of 0", dcp_level_from_nits(0, maximum), 0);
	expect_u32("level of max", dcp_level_from_nits(maximum, maximum), maximum);
	expect_int("same nits stay", needs_ramp(0, 0.0, (int)maximum), 0);
	expect_int("different nits ramp", needs_ramp(0, 100.0, (int)maximum), 1);

	for (level = 0; level <= (int)maximum; level++) {
		uint32_t p = dcp_perceptual_nits((uint32_t)level, maximum);
		uint32_t back = dcp_level_from_nits(p, maximum);
		uint32_t again = dcp_perceptual_nits(back, maximum);

		if (p < prev) {
			fprintf(stderr, "self-test: monotonic at %d: %u < %u\n", level, p, prev);
			g_failures++;
			break;
		}
		if (again != p || back > (uint32_t)level) {
			fprintf(stderr,
				"self-test: plateau at %d: perceptual %u back %u again %u\n",
				level, p, back, again);
			g_failures++;
			break;
		}
		if (!plateau && back < (uint32_t)level) {
			expect_int("plateau holds", needs_ramp(level, (double)p, (int)maximum), 0);
			plateau = 1;
		}
		prev = p;
	}
	expect_int("map has a plateau", plateau, 1);

	{
		uint32_t level100 = dcp_level_from_nits(100, maximum);
		uint32_t got = dcp_perceptual_nits(level100, maximum);

		if (got < 100) {
			fprintf(stderr, "self-test: level_from 100 maps to %u nits\n", got);
			g_failures++;
		}
	}
}

static void test_detect_and_ease(void)
{
	struct level_track tracked;

	expect_int("before first write",
		   classify_actual(1, 0, 0, 0, 0.0, -1, 40), SAMPLE_ADOPT);
	expect_int("during ramp",
		   classify_actual(1, 1, 1, 1, 0.0, 10, 40), SAMPLE_QUIET);
	expect_int("unchanged",
		   classify_actual(1, 1, 1, 0, 0.0, 10, 10), SAMPLE_QUIET);
	expect_int("external change",
		   classify_actual(1, 1, 1, 0, 0.0, 10, 40), SAMPLE_MANUAL);
	expect_int("settle suppresses",
		   classify_actual(1, 1, 1, 0, SETTLE_S, 10, 40), SAMPLE_QUIET);
	expect_int("not writable",
		   classify_actual(0, 1, 1, 0, 0.0, 10, 0), SAMPLE_QUIET);
	expect_int("resume adopts",
		   classify_actual(1, 0, 1, 0, 0.0, 10, 0), SAMPLE_ADOPT);

	expect_near("ease midpoint", ease_nits(10.0, 110.0, 1.75, EASE_S), 60.0, 1e-9);
	expect_near("ease frozen", ease_elapsed(1.0, TICK_S, 0), 1.0, 0.0);
	expect_near("ease steps", ease_elapsed(1.0, TICK_S, 1), 1.0 + TICK_S, 1e-12);

	memset(&tracked, 0, sizeof tracked);
	tracked.last_level = 10;
	tracked.last_written = 10;
	note_output(&tracked, 20, 1);
	expect_int("dry-run level", tracked.last_level, 20);
	expect_int("dry-run leaves written", tracked.last_written, 10);
	expect_near("dry-run leaves settle", tracked.settle_left, 0.0, 0.0);
	note_output(&tracked, 20, 0);
	expect_int("write records", tracked.last_written, 20);
	expect_near("write settles", tracked.settle_left, SETTLE_S, 0.0);
}

static void test_learn(void)
{
	struct learn_point pt;
	double curve_at;
	double far;

	memset(&pt, 0, sizeof pt);
	pt.valid = 1;
	pt.lux = 100.0;
	pt.nits = 200.0;
	curve_at = curve_nits(100.0);
	far = curve_nits(111.0);

	expect_near("learn off",
		    target_nits(100.0, 0.0, 0, &pt, DEFAULT_MIN_NITS, DEFAULT_MAX_NITS),
		    curve_at, 1e-9);
	expect_near("learn on near",
		    target_nits(109.0, 0.0, 1, &pt, DEFAULT_MIN_NITS, DEFAULT_MAX_NITS),
		    200.0, 1e-9);
	expect_near("learn on far",
		    target_nits(111.0, 0.0, 1, &pt, DEFAULT_MIN_NITS, DEFAULT_MAX_NITS),
		    far, 1e-9);
	expect_int("point invalid", learn_applies(1, &pt, 100.0), 1);
	pt.valid = 0;
	expect_near("learn on invalid",
		    target_nits(100.0, 0.0, 1, &pt, DEFAULT_MIN_NITS, DEFAULT_MAX_NITS),
		    curve_at, 1e-9);
}

static void test_writable_and_state(void)
{
	char buf[64];
	double parsed = 99.0;

	expect_int("panel on", panel_is_writable(0, 0, 1, 0), 1);
	expect_int("dpms off", panel_is_writable(1, 0, 1, 0), 0);
	expect_int("lid closed", panel_is_writable(0, 1, 1, 0), 0);
	expect_int("bl_power", panel_is_writable(0, 0, 1, 1), 0);
	expect_int("power unknown", panel_is_writable(0, 0, 0, 4), 1);

	expect_int("format", format_state(buf, sizeof buf, -0.5), 0);
	expect_int("format text", strcmp(buf, "offset_stops -0.50000000\n"), 0);
	expect_int("parse", parse_state(buf, &parsed), 0);
	expect_near("parsed stops", parsed, -0.5, 1e-8);
	expect_int("reject keyboard line", parse_state("offset 0.1\n", &parsed), -1);
	expect_int("reject empty", parse_state("", &parsed), -1);
	expect_int("reject nan", format_state(buf, sizeof buf, nan("")), -1);
}

static int self_test(void)
{
	g_failures = 0;
	test_curve();
	test_gate();
	test_offset_and_clamp();
	test_cie();
	test_detect_and_ease();
	test_learn();
	test_writable_and_state();
	if (g_failures) {
		fprintf(stderr, "self-test: %d failure%s\n", g_failures, g_failures == 1 ? "" : "s");
		return 1;
	}
	printf("self-test ok\n");
	return 0;
}

/* --- sysfs and input. Not used by --self-test. --- */

static int bit_is_set(const unsigned long *bits, unsigned int bit)
{
	return (bits[bit / (sizeof(unsigned long) * 8)] >>
		(bit % (sizeof(unsigned long) * 8))) & 1UL;
}

static int read_fd_text(int fd, char *buf, size_t cap)
{
	ssize_t n;

	if (cap < 2)
		return -1;
	if (lseek(fd, 0, SEEK_SET) < 0)
		return -1;
	n = read(fd, buf, cap - 1);
	if (n < 0)
		return -1;
	buf[n] = '\0';
	return 0;
}

static int read_path_text(const char *path, char *buf, size_t cap)
{
	int fd;
	int rc;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	rc = read_fd_text(fd, buf, cap);
	close(fd);
	return rc;
}

static int parse_trimmed_double(const char *s, double *out)
{
	char *end = NULL;
	double v;

	errno = 0;
	v = strtod(s, &end);
	if (end == s || errno || !isfinite(v))
		return -1;
	*out = v;
	return 0;
}

static int parse_trimmed_int(const char *s, int *out)
{
	char *end = NULL;
	long v;

	errno = 0;
	v = strtol(s, &end, 10);
	if (end == s || errno)
		return -1;
	if (v > 1000000 || v < -1000000)
		return -1;
	*out = (int)v;
	return 0;
}

static int read_fd_double(int fd, double *out)
{
	char buf[64];

	if (read_fd_text(fd, buf, sizeof buf))
		return -1;
	return parse_trimmed_double(buf, out);
}

static int read_fd_int(int fd, int *out)
{
	char buf[64];

	if (read_fd_text(fd, buf, sizeof buf))
		return -1;
	return parse_trimmed_int(buf, out);
}

static int write_fd_text(int fd, const char *text)
{
	size_t len = strlen(text);
	ssize_t n;

	if (lseek(fd, 0, SEEK_SET) < 0)
		return -1;
	n = write(fd, text, len);
	if (n < 0 || (size_t)n != len)
		return -1;
	return 0;
}

static int write_fd_int(int fd, int value)
{
	char buf[32];

	snprintf(buf, sizeof buf, "%d", value);
	return write_fd_text(fd, buf);
}

static int text_is_name(const char *text, const char *name)
{
	size_t n = strlen(name);

	while (*text == ' ' || *text == '\t')
		text++;
	if (strncmp(text, name, n) != 0)
		return 0;
	text += n;
	return *text == '\0' || *text == '\n' || *text == '\r';
}

/* First iio device whose name file is aop-sensors-als. */
static int find_als_illuminance(char *path, size_t cap)
{
	DIR *dir;
	struct dirent *ent;
	int found = 0;

	dir = opendir(IIO_ROOT);
	if (!dir)
		return -1;

	while ((ent = readdir(dir))) {
		char name_path[512];
		char name[64];

		if (strncmp(ent->d_name, "iio:", 4) != 0)
			continue;
		snprintf(name_path, sizeof name_path, "%s/%s/name", IIO_ROOT, ent->d_name);
		if (read_path_text(name_path, name, sizeof name))
			continue;
		if (!text_is_name(name, ALS_NAME))
			continue;
		snprintf(path, cap, "%s/%s/in_illuminance_input", IIO_ROOT, ent->d_name);
		found = 1;
		break;
	}
	closedir(dir);
	return found ? 0 : -1;
}

static int dpms_text_is_off(const char *s)
{
	while (*s == ' ' || *s == '\t')
		s++;
	if (strncasecmp(s, "on", 2) == 0 &&
	    (s[2] == '\0' || s[2] == '\n' || isspace((unsigned char)s[2])))
		return 0;
	return 1;
}

static int find_edp_dpms(char *path, size_t cap)
{
	DIR *dir;
	struct dirent *ent;
	char fallback[512];
	int have_fallback = 0;

	dir = opendir("/sys/class/drm");
	if (!dir)
		return -1;
	fallback[0] = '\0';

	while ((ent = readdir(dir))) {
		char status_path[512];
		char status[32];
		const char *name = ent->d_name;

		if (strncmp(name, "card", 4) != 0)
			continue;
		if (!strstr(name, "-eDP-") && !strstr(name, "-DSI-") && !strstr(name, "-LVDS-"))
			continue;
		snprintf(status_path, sizeof status_path, "/sys/class/drm/%s/status", name);
		if (read_path_text(status_path, status, sizeof status))
			continue;
		snprintf(path, cap, "/sys/class/drm/%s/dpms", name);
		if (!strncmp(status, "connected", 9)) {
			closedir(dir);
			return 0;
		}
		if (!have_fallback) {
			snprintf(fallback, sizeof fallback, "%s", path);
			have_fallback = 1;
		}
	}
	closedir(dir);
	if (!have_fallback)
		return -1;
	snprintf(path, cap, "%s", fallback);
	return 0;
}

static int device_has_sw_lid(int fd)
{
	unsigned long bits[(SW_MAX / (sizeof(unsigned long) * 8)) + 1];

	memset(bits, 0, sizeof bits);
	if (ioctl(fd, EVIOCGBIT(EV_SW, sizeof bits), bits) < 0)
		return 0;
	return bit_is_set(bits, SW_LID);
}

static int lid_is_closed(int fd)
{
	unsigned long sw[(SW_MAX / (sizeof(unsigned long) * 8)) + 1];

	memset(sw, 0, sizeof sw);
	if (ioctl(fd, EVIOCGSW(sizeof sw), sw) < 0)
		return 0;
	return bit_is_set(sw, SW_LID);
}

static void drain_lid(int fd, int *lid_closed, int *dead)
{
	for (;;) {
		struct input_event ev;
		ssize_t n = read(fd, &ev, sizeof ev);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return;
			*dead = 1;
			return;
		}
		if (n == 0) {
			*dead = 1;
			return;
		}
		if ((size_t)n != sizeof ev)
			return;
		if (ev.type == EV_SW && ev.code == SW_LID)
			*lid_closed = ev.value != 0;
	}
}

static int open_lid(int *fd_out, int *lid_closed)
{
	DIR *dir;
	struct dirent *ent;

	*fd_out = -1;
	*lid_closed = 0;
	dir = opendir("/dev/input");
	if (!dir) {
		fprintf(stderr, "ct720-display-light: cannot open /dev/input: %s; assuming lid open\n",
			strerror(errno));
		return 0;
	}
	while ((ent = readdir(dir))) {
		char path[288];
		int fd;

		if (strncmp(ent->d_name, "event", 5) != 0)
			continue;
		snprintf(path, sizeof path, "/dev/input/%s", ent->d_name);
		fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
		if (fd < 0)
			continue;
		if (!device_has_sw_lid(fd)) {
			close(fd);
			continue;
		}
		*lid_closed = lid_is_closed(fd);
		*fd_out = fd;
		closedir(dir);
		return 0;
	}
	closedir(dir);
	fprintf(stderr, "ct720-display-light: no SW_LID device; assuming lid open\n");
	return 0;
}

static int save_state(double offset_stops)
{
	char body[64];
	int fd;
	ssize_t wr;
	size_t len;

	if (format_state(body, sizeof body, offset_stops))
		return -1;
	if (mkdir(STATE_DIR, 0755) && errno != EEXIST)
		return -1;
	fd = open(STATE_TMP, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return -1;
	len = strlen(body);
	wr = write(fd, body, len);
	if (wr < 0 || (size_t)wr != len) {
		close(fd);
		return -1;
	}
	if (fsync(fd)) {
		close(fd);
		return -1;
	}
	if (close(fd))
		return -1;
	if (rename(STATE_TMP, STATE_PATH))
		return -1;
	fd = open(STATE_DIR, O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		/* The rename already landed. A directory sync failure is not fatal. */
		(void)fsync(fd);
		close(fd);
	}
	return 0;
}

static int load_state(double *offset_stops)
{
	char buf[128];

	if (read_path_text(STATE_PATH, buf, sizeof buf))
		return -1;
	return parse_state(buf, offset_stops);
}

static void usage(void)
{
	fprintf(stderr,
		"usage: ct720-display-light [options]\n"
		"  --dry-run       do not write the panel or the state file\n"
		"  --verbose       periodic status on stderr\n"
		"  --no-auto       hold the manual nits; do not follow the curve\n"
		"  --learn         session-only learned point (not saved)\n"
		"  --min-nits N    floor (default 3)\n"
		"  --max-nits N    ceiling (default 394)\n"
		"  --self-test     curve, map, and detection tests; opens nothing\n"
		"  --check-sensor  exit 1 if aop-sensors-als is absent\n");
}

static int parse_double_arg(const char *s, double *out)
{
	char *end = NULL;
	double v;

	errno = 0;
	v = strtod(s, &end);
	if (!s[0] || end == s || *end || errno || !isfinite(v))
		return -1;
	*out = v;
	return 0;
}

static int parse_args(int argc, char **argv, struct config *cfg)
{
	int i;

	memset(cfg, 0, sizeof *cfg);
	cfg->min_nits = DEFAULT_MIN_NITS;
	cfg->max_nits = DEFAULT_MAX_NITS;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--dry-run") == 0) {
			cfg->dry_run = 1;
		} else if (strcmp(argv[i], "--verbose") == 0) {
			cfg->verbose = 1;
		} else if (strcmp(argv[i], "--no-auto") == 0) {
			cfg->no_auto = 1;
		} else if (strcmp(argv[i], "--learn") == 0) {
			cfg->learn = 1;
		} else if (strcmp(argv[i], "--check-sensor") == 0) {
			cfg->check_sensor = 1;
		} else if (strcmp(argv[i], "--self-test") == 0) {
			/* main() handles this before any open. */
		} else if (strcmp(argv[i], "--min-nits") == 0 || strcmp(argv[i], "--max-nits") == 0) {
			double v;
			int is_min = argv[i][2] == 'm' && argv[i][3] == 'i';

			if (i + 1 >= argc || parse_double_arg(argv[++i], &v) || v < 0.0) {
				usage();
				return 2;
			}
			if (is_min)
				cfg->min_nits = v;
			else
				cfg->max_nits = v;
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			usage();
			return 2;
		} else {
			fprintf(stderr, "ct720-display-light: unknown option %s\n", argv[i]);
			usage();
			return 2;
		}
	}
	if (!(cfg->max_nits > cfg->min_nits)) {
		fprintf(stderr, "ct720-display-light: --max-nits must be above --min-nits\n");
		return 2;
	}
	return 0;
}

static int check_sensor(void)
{
	char path[512];

	if (find_als_illuminance(path, sizeof path)) {
		fprintf(stderr, "ct720-display-light: no aop-sensors-als\n");
		return 1;
	}
	return 0;
}

static double mono_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

struct ema {
	int inited;
	double v;
};

struct held_lux {
	int inited;
	double v;
};

static void ema_step(struct ema *e, double sample, double dt, double tau)
{
	double a;

	if (!e->inited) {
		e->inited = 1;
		e->v = sample;
		return;
	}
	if (!(tau > 0.0)) {
		e->v = sample;
		return;
	}
	if (!(dt > 0.0))
		return;
	a = 1.0 - exp(-dt / tau);
	e->v += (sample - e->v) * a;
}

static void hold_lux(struct held_lux *h, double smoothed)
{
	if (!h->inited) {
		h->inited = 1;
		h->v = smoothed;
		return;
	}
	if (lux_change_counts(h->v, smoothed))
		h->v = smoothed;
}

static int run_daemon(const struct config *cfg)
{
	char lux_path[512];
	char dpms_path[512];
	int lux_fd = -1;
	int bright_fd = -1;
	int actual_fd = -1;
	int power_fd = -1;
	int dpms_fd = -1;
	int lid_fd = -1;
	int timer_fd = -1;
	int max_brightness = 0;
	int lid_closed = 0;
	int have_sample = 0;
	int was_writable = 0;
	int easing = 0;
	int dirty = 0;
	int write_errors = 0;
	int rc = 1;
	double offset = 0.0;
	double manual_nits = DEFAULT_MIN_NITS;
	double pause_left = 0.0;
	double last_now;
	double last_status = 0.0;
	double since_save = 0.0;
	struct ema ema;
	struct held_lux held;
	struct learn_point point;
	struct level_track track;
	struct {
		int active;
		double from;
		double to;
		double elapsed;
	} ease;

	memset(&ema, 0, sizeof ema);
	memset(&held, 0, sizeof held);
	memset(&point, 0, sizeof point);
	memset(&track, 0, sizeof track);
	memset(&ease, 0, sizeof ease);
	track.last_level = -1;
	track.last_written = -1;
	dpms_path[0] = '\0';

	if (find_als_illuminance(lux_path, sizeof lux_path)) {
		fprintf(stderr, "ct720-display-light: no aop-sensors-als; nothing to do\n");
		return 0;
	}
	if (access(BL_BRIGHT, F_OK) != 0) {
		fprintf(stderr, "ct720-display-light: no apple-panel-bl; nothing to do\n");
		return 0;
	}

	lux_fd = open(lux_path, O_RDONLY | O_CLOEXEC);
	if (lux_fd < 0) {
		if (errno == ENOENT) {
			fprintf(stderr, "ct720-display-light: no aop-sensors-als; nothing to do\n");
			return 0;
		}
		fprintf(stderr, "ct720-display-light: cannot open %s: %s\n", lux_path, strerror(errno));
		return 1;
	}
	bright_fd = open(BL_BRIGHT, (cfg->dry_run ? O_RDONLY : O_RDWR) | O_CLOEXEC);
	if (bright_fd < 0) {
		if (errno == ENOENT) {
			fprintf(stderr, "ct720-display-light: no apple-panel-bl; nothing to do\n");
			rc = 0;
			goto out;
		}
		fprintf(stderr, "ct720-display-light: cannot open %s: %s\n", BL_BRIGHT, strerror(errno));
		goto out;
	}
	{
		int max_fd = open(BL_MAX, O_RDONLY | O_CLOEXEC);

		if (max_fd < 0 || read_fd_int(max_fd, &max_brightness) || max_brightness <= 0) {
			fprintf(stderr, "ct720-display-light: cannot read %s: %s\n", BL_MAX, strerror(errno));
			if (max_fd >= 0)
				close(max_fd);
			goto out;
		}
		close(max_fd);
	}
	actual_fd = open(BL_ACTUAL, O_RDONLY | O_CLOEXEC);
	if (actual_fd < 0) {
		fprintf(stderr, "ct720-display-light: cannot open %s: %s\n", BL_ACTUAL, strerror(errno));
		goto out;
	}
	power_fd = open(BL_POWER, O_RDONLY | O_CLOEXEC);
	if (find_edp_dpms(dpms_path, sizeof dpms_path) == 0)
		dpms_fd = open(dpms_path, O_RDONLY | O_CLOEXEC);
	else
		fprintf(stderr, "ct720-display-light: no eDP DPMS node; assuming the panel is on\n");

	if (open_lid(&lid_fd, &lid_closed))
		goto out;

	if (access(STATE_PATH, R_OK) == 0) {
		if (load_state(&offset))
			fprintf(stderr, "ct720-display-light: ignoring unreadable %s\n", STATE_PATH);
	}

	timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	if (timer_fd < 0) {
		fprintf(stderr, "ct720-display-light: timerfd: %s\n", strerror(errno));
		goto out;
	}
	{
		struct itimerspec spec;

		memset(&spec, 0, sizeof spec);
		spec.it_interval.tv_nsec = 50000000L;
		spec.it_value.tv_nsec = 50000000L;
		if (timerfd_settime(timer_fd, 0, &spec, NULL)) {
			fprintf(stderr, "ct720-display-light: timerfd_settime: %s\n", strerror(errno));
			goto out;
		}
	}

	fprintf(stderr,
		"ct720-display-light: %sCT720 -> apple-panel-bl (max %d, %.0f..%.0f nits)%s%s\n",
		cfg->dry_run ? "dry-run " : "",
		max_brightness, cfg->min_nits, cfg->max_nits,
		cfg->no_auto ? ", manual hold" : "",
		cfg->learn ? ", learn" : "");
	if (lid_fd >= 0)
		fprintf(stderr, "ct720-display-light: lid %s\n", lid_closed ? "closed" : "open");
	if (dpms_fd >= 0)
		fprintf(stderr, "ct720-display-light: dpms %s\n", dpms_path);

	last_now = mono_now();
	while (!g_stop) {
		struct pollfd pfds[2];
		int poll_n = 1;
		int pr;
		uint64_t expirations;
		double now;
		double dt;
		double sample;
		int actual = 0;
		int bl_power = 0;
		int power_known = 0;
		int dpms_off = 0;
		int writable;
		int kind;
		int lid_dead = 0;

		pfds[0].fd = timer_fd;
		pfds[0].events = POLLIN;
		pfds[0].revents = 0;
		if (lid_fd >= 0) {
			pfds[1].fd = lid_fd;
			pfds[1].events = POLLIN;
			pfds[1].revents = 0;
			poll_n = 2;
		}
		pr = poll(pfds, (nfds_t)poll_n, -1);
		if (pr < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "ct720-display-light: poll: %s\n", strerror(errno));
			goto out;
		}
		if (lid_fd >= 0 && (pfds[1].revents & (POLLERR | POLLHUP | POLLNVAL))) {
			fprintf(stderr, "ct720-display-light: lid device closed; assuming open\n");
			close(lid_fd);
			lid_fd = -1;
			lid_closed = 0;
		} else if (lid_fd >= 0 && (pfds[1].revents & POLLIN)) {
			drain_lid(lid_fd, &lid_closed, &lid_dead);
			if (lid_dead) {
				fprintf(stderr, "ct720-display-light: lid read failed; assuming open\n");
				close(lid_fd);
				lid_fd = -1;
				lid_closed = 0;
			}
		}
		if (!(pfds[0].revents & POLLIN))
			continue;
		if (read(timer_fd, &expirations, sizeof expirations) < 0 && errno != EAGAIN)
			continue;
		(void)expirations;

		now = mono_now();
		dt = now - last_now;
		if (dt < 0.0)
			dt = 0.0;
		if (dt > 1.0)
			dt = 1.0;
		last_now = now;
		since_save += dt;

		if (read_fd_double(lux_fd, &sample)) {
			fprintf(stderr, "ct720-display-light: lux read failed: %s\n", strerror(errno));
			continue;
		}
		if (sample < 0.0)
			sample = 0.0;
		ema_step(&ema, sample, dt, LUX_EMA_TAU);
		hold_lux(&held, ema.v);

		if (read_fd_int(actual_fd, &actual)) {
			fprintf(stderr, "ct720-display-light: actual_brightness read failed: %s\n",
				strerror(errno));
			continue;
		}
		if (actual < 0)
			actual = 0;
		if (power_fd >= 0 && read_fd_int(power_fd, &bl_power) == 0)
			power_known = 1;
		if (dpms_fd >= 0) {
			char text[32];

			if (read_fd_text(dpms_fd, text, sizeof text) == 0)
				dpms_off = dpms_text_is_off(text);
		}

		writable = panel_is_writable(dpms_off, lid_closed, power_known, bl_power);
		if (pause_left > 0.0) {
			pause_left -= dt;
			if (pause_left < 0.0)
				pause_left = 0.0;
		}

		/*
		 * Not writable: do not move the ramp and do not treat the
		 * reading (often 0 while blanked) as a manual change.
		 */
		if (!writable) {
			was_writable = 0;
			goto maybe_save;
		}

		kind = classify_actual(writable, was_writable, have_sample, easing,
				       track.settle_left, track.last_written, actual);
		was_writable = 1;
		if (track.settle_left > 0.0) {
			track.settle_left -= dt;
			if (track.settle_left < 0.0)
				track.settle_left = 0.0;
		}

		if (kind == SAMPLE_ADOPT) {
			have_sample = 1;
			easing = 0;
			ease.active = 0;
			track.settle_left = 0.0;
			track.last_written = actual;
			track.last_level = actual;
			manual_nits = (double)dcp_perceptual_nits((uint32_t)actual,
								 (uint32_t)max_brightness);
			goto maybe_save;
		}
		if (kind == SAMPLE_MANUAL) {
			double user = (double)dcp_perceptual_nits((uint32_t)actual,
								 (uint32_t)max_brightness);

			offset = offset_stops_from(user, curve_nits(held.v), cfg->min_nits);
			manual_nits = user;
			pause_left = MANUAL_PAUSE_S;
			easing = 0;
			ease.active = 0;
			track.settle_left = 0.0;
			track.last_written = actual;
			track.last_level = actual;
			dirty = 1;
			if (cfg->learn && held.v > 0.0) {
				point.valid = 1;
				point.lux = held.v;
				point.nits = user;
			}
			fprintf(stderr, "ct720-display-light: manual level %d offset %.3f\n",
				actual, offset);
			goto maybe_save;
		}

		if (pause_left > 0.0)
			goto maybe_save;

		{
			double want;
			double shown;
			int level;

			if (cfg->no_auto)
				want = manual_nits;
			else
				want = target_nits(held.v, offset, cfg->learn, &point,
						   cfg->min_nits, cfg->max_nits);

			if (ease.active && fabs(ease.to - want) > 0.25) {
				ease.from = ease_nits(ease.from, ease.to, ease.elapsed, EASE_S);
				ease.to = want;
				ease.elapsed = 0.0;
			} else if (!ease.active && needs_ramp(track.last_level, want, max_brightness)) {
				ease.active = 1;
				ease.from = (double)dcp_perceptual_nits(
					(uint32_t)(track.last_level < 0 ? 0 : track.last_level),
					(uint32_t)max_brightness);
				ease.to = want;
				ease.elapsed = 0.0;
			}

			if (ease.active) {
				ease.elapsed = ease_elapsed(ease.elapsed, dt, 1);
				shown = ease_nits(ease.from, ease.to, ease.elapsed, EASE_S);
				easing = ease.elapsed < EASE_S;
				if (!easing)
					ease.active = 0;
			} else {
				shown = want;
				easing = 0;
			}

			level = level_for_nits(ease.active || easing ? shown : want, max_brightness);
			if (level != track.last_level &&
			    needs_ramp(track.last_level, ease.active || easing ? shown : want,
				       max_brightness)) {
				if (!cfg->dry_run) {
					if (write_fd_int(bright_fd, level)) {
						write_errors++;
						fprintf(stderr,
							"ct720-display-light: brightness write %d failed: %s\n",
							level, strerror(errno));
						if (write_errors >= 20)
							goto out;
						goto maybe_save;
					}
					write_errors = 0;
					note_output(&track, level, 0);
				} else {
					note_output(&track, level, 1);
				}
				if (cfg->verbose) {
					fprintf(stderr,
						"ct720-display-light:%s level %d (lux %.1f nits %.1f offset %.3f)\n",
						cfg->dry_run ? " dry-run" : "",
						level, held.v, shown, offset);
				}
			}
		}

maybe_save:
		if (!cfg->dry_run && dirty && since_save >= SAVE_EVERY_S) {
			if (save_state(offset))
				fprintf(stderr, "ct720-display-light: cannot save offset: %s\n",
					strerror(errno));
			else
				dirty = 0;
			since_save = 0.0;
		}
		if (cfg->verbose && now - last_status >= 2.0) {
			fprintf(stderr,
				"ct720-display-light: status lux %.1f held %.1f actual %d dpms %s bl %d lid %s offset %.3f\n",
				ema.v, held.v, actual,
				dpms_fd < 0 ? "n/a" : (dpms_off ? "off" : "on"),
				power_known ? bl_power : -1,
				lid_closed ? "closed" : "open",
				offset);
			last_status = now;
		}
	}

	rc = 0;
	fprintf(stderr, "ct720-display-light: stopping\n");

out:
	if (!cfg->dry_run && dirty) {
		if (save_state(offset))
			fprintf(stderr, "ct720-display-light: cannot save offset: %s\n",
				strerror(errno));
	}
	if (timer_fd >= 0)
		close(timer_fd);
	if (lid_fd >= 0)
		close(lid_fd);
	if (dpms_fd >= 0)
		close(dpms_fd);
	if (power_fd >= 0)
		close(power_fd);
	if (actual_fd >= 0)
		close(actual_fd);
	if (bright_fd >= 0)
		close(bright_fd);
	if (lux_fd >= 0)
		close(lux_fd);
	return rc;
}

int main(int argc, char **argv)
{
	struct config cfg;
	struct sigaction sa;
	int i;
	int parsed;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--self-test") == 0)
			return self_test();
	}

	parsed = parse_args(argc, argv, &cfg);
	if (parsed)
		return parsed;
	if (cfg.check_sensor)
		return check_sensor();

	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	return run_daemon(&cfg);
}
