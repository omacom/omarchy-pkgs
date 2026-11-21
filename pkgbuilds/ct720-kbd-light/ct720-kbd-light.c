/*
 * ct720-kbd-light — keyboard backlight for the MacBook Air (M1, 2020), J313.
 *
 * The CT720 ambient-light sensor chooses the level. A brightness the daemon
 * did not write becomes an offset from that curve and is kept across boots.
 * Manual off stays off until the user turns the lamp up. The result fades
 * with the panel and, unless idle hold is "never", after the keyboard and
 * trackpad go idle.
 *
 * The only backlight write is /sys/class/leds/kbd_backlight/brightness.
 * The PWM controller is left alone.
 *
 * Without the CT720 lux sensor (sysfs name aop-sensors-als) and
 * kbd_backlight, the process exits without writing the LED.
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
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#include <linux/input.h>

static const char IIO_DEVICES[] = "/sys/bus/iio/devices";
static const char KBD_BRIGHT_PATH[] = "/sys/class/leds/kbd_backlight/brightness";
static const char KBD_MAX_PATH[] = "/sys/class/leds/kbd_backlight/max_brightness";
static const char KBD_TRIGGER_PATH[] = "/sys/class/leds/kbd_backlight/trigger";
static const char PANEL_ACTUAL_PATH[] = "/sys/class/backlight/apple-panel-bl/actual_brightness";
static const char PANEL_MAX_PATH[] = "/sys/class/backlight/apple-panel-bl/max_brightness";
static const char PANEL_POWER_PATH[] = "/sys/class/backlight/apple-panel-bl/bl_power";
/* Userspace name of the CT720 behind apple,t8103-aop-als. */
static const char CT720_IIO_NAME[] = "aop-sensors-als";
/* Consecutive lux failures before the held sample is the bounded fallback. */
enum { LUX_FAIL_BOUND = 20 };
enum { LUX_WAIT = 0, LUX_HOLD = 1, LUX_FALLBACK = 2 };
static const char OFFSET_PATH[] = "/var/lib/ct720-kbd-light/offset";

static const char KBD_INPUT_NAME[] = "Apple SPI Keyboard";
static const char PAD_INPUT_NAME[] = "Apple SPI Trackpad";

static const double TICK_S = 0.050;
static const double LUX_EMA_TAU = 0.50;
static const double LUX_BRIGHT_WINDOW = 0.40;
static const double DISPLAY_FOLLOW_DROP = 0.12;
static const double DISPLAY_RELEASE_AFTER = 0.70;
static const double DISPLAY_RELEASE_MIN = 0.08;
static const double DISPLAY_LATCH_SETTLE = 0.50;
static const double DISPLAY_STILL_EPS = 0.008;
static const double DISPLAY_BLANK_EPS = 0.004;
static const double DISPLAY_SLEW_DOWN = 0.45;
static const double DISPLAY_SLEW_UP = 0.35;
static const double MANUAL_PAUSE_S = 2.0;
static const double FADE_MANUAL_S = 0.350;
static const double FADE_AUTO_S = 0.500;

/* Above this lux the keys are readable without the lamp. */
struct lux_knot {
	double lux;
	double frac;
};

static const struct lux_knot LUX_KNOTS[] = {
	{ 0.0, 1.00 },
	{ 1.0, 0.92 },
	{ 5.0, 0.70 },
	{ 15.0, 0.45 },
	{ 40.0, 0.22 },
	{ 90.0, 0.08 },
	{ 160.0, 0.02 },
	{ 250.0, 0.00 },
};

enum { LUX_KNOT_COUNT = sizeof LUX_KNOTS / sizeof LUX_KNOTS[0] };
enum { MAX_INPUTS = 8 };

struct config {
	int verbose;
	int dry_run;
	int no_auto;
	int idle_never;
	int have_lux_override;
	double lux_override;
	double idle_hold;
	double idle_fade;
	double wake_fade;
};

struct lux_ema {
	int inited;
	double v;
	double up_only_left;
};

struct display_fade {
	int inited;
	int following;
	double latched;
	double last;
	double still_for;
	double gain;
};

struct idle_fade {
	int inited;
	double gain;
	double last_activity;
};

struct input_src {
	int fd;
	int activity;
	int lid;
	char name[128];
	unsigned char buf[sizeof(struct input_event) * 32];
	size_t fill;
};

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static double mono_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static double clamp01(double x)
{
	if (x < 0.0)
		return 0.0;
	if (x > 1.0)
		return 1.0;
	return x;
}

static int bit_is_set(const unsigned long *bits, unsigned int bit)
{
	return (bits[bit / (sizeof(unsigned long) * 8)] >>
		(bit % (sizeof(unsigned long) * 8))) & 1UL;
}

/*
 * Fraction of full keyboard brightness for an illuminance in lux.
 * At or below 0 lux the lamp is full. At 250 lux and above it is off.
 * Between the knots the curve is linear in log lux, which matches the
 * way a room goes from "needs the lamp" to "the legends are readable".
 */
static double lux_to_fraction(double lux)
{
	int i;

	if (!(lux > 0.0))
		return LUX_KNOTS[0].frac;
	if (lux >= LUX_KNOTS[LUX_KNOT_COUNT - 1].lux)
		return LUX_KNOTS[LUX_KNOT_COUNT - 1].frac;

	if (lux < LUX_KNOTS[1].lux) {
		double t = lux / LUX_KNOTS[1].lux;

		return LUX_KNOTS[0].frac + t * (LUX_KNOTS[1].frac - LUX_KNOTS[0].frac);
	}

	for (i = 1; i < LUX_KNOT_COUNT - 1; i++) {
		if (lux <= LUX_KNOTS[i + 1].lux)
			break;
	}

	{
		double x0 = log(LUX_KNOTS[i].lux);
		double x1 = log(LUX_KNOTS[i + 1].lux);
		double t = (log(lux) - x0) / (x1 - x0);

		return LUX_KNOTS[i].frac + t * (LUX_KNOTS[i + 1].frac - LUX_KNOTS[i].frac);
	}
}

/*
 * Smooth the sensor. The first LUX_BRIGHT_WINDOW seconds only move upward,
 * so a single not-ready 0 lux sample cannot flash the lamp on at boot.
 * Returns 1 once the window has passed and the value may drive the LED.
 */
static int lux_ema_step(struct lux_ema *e, double sample, double dt, double tau, double bright_window)
{
	if (dt < 0.0)
		dt = 0.0;

	if (!e->inited) {
		e->inited = 1;
		e->v = sample;
		e->up_only_left = bright_window;
		return bright_window <= 0.0;
	}

	if (e->up_only_left > 0.0) {
		if (sample > e->v)
			e->v = sample;
		e->up_only_left -= dt;
		/* Tick sizes are not exact in binary, so a remainder under a
		 * millisecond means the startup window is over. */
		if (e->up_only_left > 1e-3)
			return 0;
		e->up_only_left = 0.0;
		return 1;
	}

	if (tau <= 0.0) {
		e->v = sample;
		return 1;
	}

	{
		double a = 1.0 - exp(-dt / tau);

		e->v += (sample - e->v) * a;
	}
	return 1;
}

static void slew_toward(double *cur, double target, double dt, double tau)
{
	double a;

	target = clamp01(target);
	if (tau <= 0.0) {
		*cur = target;
		return;
	}
	a = 1.0 - exp(-dt / tau);
	*cur += (target - *cur) * a;
	if (fabs(*cur - target) < 0.004)
		*cur = target;
	*cur = clamp01(*cur);
}

/*
 * panel_frac is 0..1 while the panel is lit, and negative when it is blanked
 * (DPMS off, backlight power not unblank, or the lid shut).
 *
 * A small slider step leaves the keyboard alone. A sustained fall of at least
 * DISPLAY_FOLLOW_DROP, or a blank, fades the keyboard with the panel. If the
 * panel then sits still at a clearly-on level, the keyboard eases back to the
 * lux level so a brightness-key nudge does not leave the lamp stuck dim.
 */
static void display_fade_step(struct display_fade *d, double panel_frac, double dt)
{
	int blank;
	double panel;
	double target;
	int track;

	if (dt < 0.0)
		dt = 0.0;
	if (dt > 1.0)
		dt = 1.0;

	blank = panel_frac < 0.0;
	panel = blank ? 0.0 : clamp01(panel_frac);

	if (!d->inited) {
		d->inited = 1;
		d->last = panel;
		d->latched = panel > DISPLAY_BLANK_EPS ? panel : 1.0;
		d->following = blank || panel <= DISPLAY_BLANK_EPS;
		d->gain = d->following ? 0.0 : 1.0;
		d->still_for = 0.0;
		return;
	}

	target = 1.0;
	track = 0;

	if (d->following && !blank && panel > d->last + 0.02) {
		d->following = 0;
		d->latched = panel;
		d->still_for = 0.0;
		target = 1.0;
	} else if (blank || panel <= DISPLAY_BLANK_EPS) {
		if (!d->following) {
			d->following = 1;
			if (d->latched < 0.05)
				d->latched = d->last > 0.05 ? d->last : 1.0;
		}
		d->still_for = 0.0;
		target = 0.0;
	} else if (d->following || panel < d->latched - DISPLAY_FOLLOW_DROP) {
		if (!d->following)
			d->following = 1;
		if (fabs(panel - d->last) <= DISPLAY_STILL_EPS)
			d->still_for += dt;
		else
			d->still_for = 0.0;
		if (d->still_for >= DISPLAY_RELEASE_AFTER && panel >= DISPLAY_RELEASE_MIN) {
			d->following = 0;
			d->latched = panel;
			d->still_for = 0.0;
			target = 1.0;
		} else {
			target = clamp01(panel / d->latched);
			track = 1;
		}
	} else {
		d->following = 0;
		if (panel > d->latched)
			d->latched = panel;
		if (fabs(panel - d->last) <= DISPLAY_STILL_EPS)
			d->still_for += dt;
		else
			d->still_for = 0.0;
		if (panel < d->latched && d->still_for >= DISPLAY_LATCH_SETTLE)
			d->latched = panel;
		target = 1.0;
	}

	if (track)
		d->gain = target;
	else
		slew_toward(&d->gain, target, dt, target < d->gain ? DISPLAY_SLEW_DOWN : DISPLAY_SLEW_UP);

	d->last = panel;
}

/*
 * Full level until idle_hold seconds without activity, then a smoothstep to
 * off over idle_fade. A new key or trackpad event eases back over wake_fade
 * instead of popping on.
 */
static void idle_fade_step(struct idle_fade *s, double now, int activity, double dt,
			   double hold, double fade, double wake)
{
	double idle_for;
	double want;
	double u;

	if (dt < 0.0)
		dt = 0.0;

	if (!s->inited) {
		s->inited = 1;
		s->gain = 1.0;
		s->last_activity = now;
	}
	if (activity)
		s->last_activity = now;

	idle_for = now - s->last_activity;
	if (idle_for < 0.0)
		idle_for = 0.0;

	if (fade <= 0.0 || idle_for <= hold) {
		want = 1.0;
	} else if (idle_for >= hold + fade) {
		want = 0.0;
	} else {
		u = (idle_for - hold) / fade;
		u = u * u * (3.0 - 2.0 * u);
		want = 1.0 - u;
	}

	if (want + 1e-9 >= s->gain) {
		if (wake <= 0.0)
			s->gain = want;
		else {
			s->gain += dt / wake;
			if (s->gain > want)
				s->gain = want;
		}
	} else {
		s->gain = want;
	}
	s->gain = clamp01(s->gain);
}

static int level_from(double amb, double disp, double idle, int max_brightness)
{
	double x;

	if (max_brightness <= 0)
		return 0;
	x = clamp01(amb) * clamp01(disp) * clamp01(idle) * (double)max_brightness;
	if (x < 0.0)
		x = 0.0;
	if (x > (double)max_brightness)
		x = (double)max_brightness;
	return (int)lround(x);
}

/*
 * curve is lux_to_fraction. offset is the user's manual shift from that curve.
 * Mute forces off. --no-auto holds manual_frac and applies only the idle fade.
 * Otherwise the level is clamp01(curve + offset) * disp * idle.
 */
static double applied_fraction(double curve, double offset, double disp, double idle,
			       int muted, int no_auto, double manual_frac)
{
	if (muted)
		return 0.0;
	idle = clamp01(idle);
	if (no_auto)
		return clamp01(manual_frac) * idle;
	return clamp01(curve + offset) * clamp01(disp) * idle;
}

/* An external write counts once we have written, including during a fade.
 * The LED sysfs node stores the integer we wrote, so readback matches it
 * with no rounding window. */
static int manual_change_detected(int observed, int last_written)
{
	if (last_written < 0)
		return 0;
	return observed != last_written;
}

/* Dry-run does not write the LED. A simulated level must not become the
 * value the next readback is compared with, or the unchanged lamp looks
 * like a manual change. */
static int note_applied_level(int dry_run, int level, int last_written)
{
	if (dry_run)
		return last_written;
	return level;
}

/* A new fade starts from the level the daemon last applied. Dry-run
 * leaves last_written at the physical brightness, so the simulated ramp
 * has to start from last_level or it restarts on every tick. */
static int fade_from_level(int dry_run, int last_level, int last_written,
			   int target)
{
	int from = dry_run ? last_level : last_written;

	return from >= 0 ? from : target;
}

/* Advance the consecutive lux-failure count, capped at bound. *log is 1
 * only when the count first becomes 1 and when it first reaches bound. */
static int lux_error_advance(int errors, int bound, int *log)
{
	if (bound > 0 && errors < bound)
		errors++;
	else {
		*log = 0;
		return errors;
	}
	*log = errors == 1 || errors == bound;
	return errors;
}

/* A failed lux read keeps the last good sample so panel, lid, and idle
 * still run. Before smoothed lux may drive the lamp, wait. After
 * LUX_FAIL_BOUND failures the held sample is the fallback and stays held
 * until a read succeeds. */
static int lux_failure_action(int driving, int consecutive_errors, int bound)
{
	if (!driving)
		return LUX_WAIT;
	if (bound > 0 && consecutive_errors >= bound)
		return LUX_FALLBACK;
	return LUX_HOLD;
}

static double offset_from_manual(int level, int max_brightness, double curve)
{
	if (max_brightness <= 0)
		return 0.0;
	return (double)level / (double)max_brightness - curve;
}

static double fade_duration(int manual)
{
	return manual ? FADE_MANUAL_S : FADE_AUTO_S;
}

struct level_fade {
	int active;
	int from;
	int to;
	double elapsed;
	double duration;
};

/* Step a linear fade. *fading is 1 while an intermediate level is in use. */
static int fade_level(struct level_fade *f, int target, int from_level, double dt,
		      double duration, int *fading)
{
	double u;

	if (dt < 0.0)
		dt = 0.0;
	if (f->active && f->duration == duration) {
		f->to = target;
		f->elapsed += dt;
		if (f->elapsed >= f->duration) {
			f->active = 0;
			*fading = 0;
			return f->to;
		}
		*fading = 1;
		u = f->elapsed / f->duration;
		return (int)lround((double)f->from + ((double)f->to - (double)f->from) * u);
	}
	if (from_level < 0 || from_level == target || duration <= 0.0) {
		f->active = 0;
		*fading = 0;
		return target;
	}
	f->active = 1;
	f->from = from_level;
	f->to = target;
	f->elapsed = 0.0;
	f->duration = duration;
	*fading = 1;
	return from_level;
}

static int format_state(char *buf, size_t cap, double offset, int muted)
{
	int n;

	n = snprintf(buf, cap, "offset %.8f\nmuted %d\n", offset, muted ? 1 : 0);
	if (n < 0 || (size_t)n >= cap)
		return -1;
	return 0;
}

static int parse_state(const char *text, double *offset, int *muted)
{
	const char *p = text;
	double off = 0.0;
	int mute = 0;
	int saw_off = 0;
	int saw_mute = 0;

	while (*p) {
		if (strncmp(p, "offset ", 7) == 0) {
			char *end = NULL;

			errno = 0;
			off = strtod(p + 7, &end);
			if (end == p + 7 || errno || off != off)
				return -1;
			saw_off = 1;
			p = end;
		} else if (strncmp(p, "muted ", 6) == 0) {
			char *end = NULL;
			long v;

			errno = 0;
			v = strtol(p + 6, &end, 10);
			if (end == p + 6 || errno || (v != 0 && v != 1))
				return -1;
			mute = (int)v;
			saw_mute = 1;
			p = end;
		} else if (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') {
			p++;
			continue;
		} else {
			return -1;
		}
	}
	if (!saw_off || !saw_mute)
		return -1;
	*offset = off;
	*muted = mute;
	return 0;
}

static int failures;

static void expect_near(const char *name, double got, double want, double tol)
{
	if (fabs(got - want) > tol) {
		fprintf(stderr, "FAIL %s: got %.6f want %.6f tol %.6f\n", name, got, want, tol);
		failures++;
	}
}

static void expect_int(const char *name, int got, int want)
{
	if (got != want) {
		fprintf(stderr, "FAIL %s: got %d want %d\n", name, got, want);
		failures++;
	}
}

static void expect_true(const char *name, int cond)
{
	if (!cond) {
		fprintf(stderr, "FAIL %s\n", name);
		failures++;
	}
}

static void test_lux_curve(void)
{
	double prev;
	int lux;

	expect_near("lux 0", lux_to_fraction(0.0), 1.0, 1e-9);
	expect_near("lux negative", lux_to_fraction(-3.0), 1.0, 1e-9);
	expect_near("lux 1", lux_to_fraction(1.0), 0.92, 1e-9);
	expect_near("lux 5", lux_to_fraction(5.0), 0.70, 1e-9);
	expect_near("lux 40", lux_to_fraction(40.0), 0.22, 1e-9);
	expect_near("lux 250", lux_to_fraction(250.0), 0.0, 1e-9);
	expect_near("lux 381", lux_to_fraction(381.0), 0.0, 1e-9);
	expect_near("lux 10000", lux_to_fraction(10000.0), 0.0, 1e-9);

	prev = lux_to_fraction(0.0);
	for (lux = 1; lux <= 2000; lux++) {
		double f = lux_to_fraction((double)lux);

		if (f > prev + 1e-9 || f < -1e-9 || f > 1.0 + 1e-9) {
			fprintf(stderr, "FAIL lux monotonic at %d: %.6f after %.6f\n", lux, f, prev);
			failures++;
			break;
		}
		prev = f;
	}
}

static void test_lux_ema(void)
{
	struct lux_ema e;
	int ready;

	memset(&e, 0, sizeof e);
	ready = lux_ema_step(&e, 0.0, 0.05, LUX_EMA_TAU, LUX_BRIGHT_WINDOW);
	expect_int("ema first not ready", ready, 0);
	expect_near("ema first value", e.v, 0.0, 1e-9);

	ready = lux_ema_step(&e, 400.0, 0.05, LUX_EMA_TAU, LUX_BRIGHT_WINDOW);
	expect_int("ema bright sample still in window", ready, 0);
	expect_near("ema took the brighter sample", e.v, 400.0, 1e-9);

	/* The first sample does not consume the window. 0.05 s is already
	 * spent, so 0.35 s finishes the 0.40 s bright-biased startup. */
	ready = lux_ema_step(&e, 100.0, 0.35, LUX_EMA_TAU, LUX_BRIGHT_WINDOW);
	expect_int("ema window elapsed", ready, 1);
	expect_near("ema ignored the darker sample in the window", e.v, 400.0, 1e-9);

	ready = lux_ema_step(&e, 400.0, 5.0, LUX_EMA_TAU, LUX_BRIGHT_WINDOW);
	expect_int("ema stays ready", ready, 1);
	expect_near("ema long dt reaches the sample", e.v, 400.0, 0.01);

	memset(&e, 0, sizeof e);
	ready = lux_ema_step(&e, 4.0, 0.05, LUX_EMA_TAU, 0.0);
	expect_int("ema zero window is immediate", ready, 1);
	expect_near("ema zero window value", e.v, 4.0, 1e-9);
}

static void test_display_fade(void)
{
	struct display_fade d;
	double prev;
	int i;
	int followed;

	memset(&d, 0, sizeof d);
	display_fade_step(&d, 1.0, 0.05);
	expect_near("display start", d.gain, 1.0, 1e-9);

	prev = d.gain;
	followed = 0;
	for (i = 1; i <= 20; i++) {
		double panel = 1.0 - (double)i * 0.05;

		display_fade_step(&d, panel, 0.05);
		if (panel < 1.0 - DISPLAY_FOLLOW_DROP && panel > DISPLAY_BLANK_EPS) {
			followed = 1;
			expect_near("display tracks panel", d.gain, panel, 0.03);
			expect_true("display fade does not rise", d.gain <= prev + 1e-9);
		} else if (panel > DISPLAY_BLANK_EPS) {
			expect_near("display ignores the first part of the fall", d.gain, 1.0, 0.02);
		}
		prev = d.gain;
	}
	expect_true("display follow engaged", followed);
	expect_true("display nearly off at the end of the ramp", d.gain < 0.08);

	for (i = 0; i < 60; i++)
		display_fade_step(&d, -1.0, 0.05);
	expect_near("display blank settles off", d.gain, 0.0, 1e-9);

	display_fade_step(&d, 1.0, 0.05);
	for (i = 0; i < 40; i++)
		display_fade_step(&d, 1.0, 0.05);
	expect_near("display back on", d.gain, 1.0, 0.02);

	memset(&d, 0, sizeof d);
	display_fade_step(&d, 1.0, 0.05);
	display_fade_step(&d, 0.95, 0.05);
	for (i = 0; i < 20; i++)
		display_fade_step(&d, 0.95, 0.05);
	expect_near("small slider step keeps the lamp", d.gain, 1.0, 0.02);

	display_fade_step(&d, 0.80, 0.05);
	expect_near("larger drop follows from the settled latch", d.gain, 0.80 / 0.95, 0.03);
}

static void test_idle_fade(void)
{
	struct idle_fade s;
	double t;
	const double hold = 10.0;
	const double fade = 1.2;
	const double wake = 0.30;
	const double dt = 0.05;

	memset(&s, 0, sizeof s);
	idle_fade_step(&s, 0.0, 1, dt, hold, fade, wake);
	for (t = dt; t <= hold + 1e-9; t += dt)
		idle_fade_step(&s, t, 0, dt, hold, fade, wake);
	expect_near("idle still on at the hold", s.gain, 1.0, 1e-9);

	for (; t <= hold + fade / 2.0 + 1e-9; t += dt)
		idle_fade_step(&s, t, 0, dt, hold, fade, wake);
	expect_near("idle halfway down", s.gain, 0.5, 0.02);

	for (; t <= hold + fade + 1e-9; t += dt)
		idle_fade_step(&s, t, 0, dt, hold, fade, wake);
	expect_near("idle faded out", s.gain, 0.0, 1e-9);

	idle_fade_step(&s, t, 1, dt, hold, fade, wake);
	t += dt;
	for (int i = 1; i < 6; i++) {
		idle_fade_step(&s, t, 0, dt, hold, fade, wake);
		t += dt;
	}
	expect_near("idle wake", s.gain, 1.0, 0.02);
}

static void test_level(void)
{
	expect_int("level full", level_from(1.0, 1.0, 1.0, 255), 255);
	expect_int("level half idle", level_from(1.0, 1.0, 0.0, 255), 0);
	expect_int("level display off", level_from(1.0, 0.0, 1.0, 255), 0);
	expect_int("level dark room", level_from(0.70, 1.0, 1.0, 255), 179);
	expect_int("level both gains", level_from(0.5, 0.5, 1.0, 255), 64);
	expect_int("level zero max", level_from(1.0, 1.0, 1.0, 0), 0);
}

static void test_offset_mute_manual(void)
{
	const double curve = lux_to_fraction(5.0);
	double off;
	char buf[128];
	double parsed;
	int muted;
	struct level_fade fade;
	int fading = 0;
	int level;

	expect_near("curve at 5 lux", curve, 0.70, 1e-9);
	off = offset_from_manual(128, 255, curve);
	expect_near("offset from half", off, 128.0 / 255.0 - 0.70, 1e-12);
	expect_near("applied offset lands on the manual fraction",
		    applied_fraction(curve, off, 1.0, 1.0, 0, 0, 0.0),
		    128.0 / 255.0, 1e-12);
	expect_near("applied clamps above full",
		    applied_fraction(1.0, 0.40, 1.0, 1.0, 0, 0, 0.0), 1.0, 1e-12);
	expect_near("applied display and idle",
		    applied_fraction(0.70, 0.0, 0.5, 0.5, 0, 0, 0.0), 0.175, 1e-12);

	expect_near("muted stays off",
		    applied_fraction(1.0, 0.0, 1.0, 1.0, 1, 0, 0.0), 0.0, 1e-12);
	expect_near("muted ignores a curve that the old offset would relight",
		    applied_fraction(1.0, -0.20, 1.0, 1.0, 1, 0, 1.0), 0.0, 1e-12);
	expect_near("mute offset", offset_from_manual(0, 255, 0.70), -0.70, 1e-12);
	expect_int("zero level is the mute signal", offset_from_manual(0, 255, 0.70) < 0.0, 1);

	expect_near("no-auto holds the manual level and idle only",
		    applied_fraction(0.10, 0.90, 0.20, 0.50, 0, 1, 0.80), 0.40, 1e-12);

	expect_int("no detect before the first write", manual_change_detected(10, -1), 0);
	expect_int("detect a manual change during a fade", manual_change_detected(10, 20), 1);
	expect_int("no detect when the fade readback is ours", manual_change_detected(20, 20), 0);
	expect_int("detect an external write", manual_change_detected(0, 20), 1);
	expect_int("dry-run keeps the last real write", note_applied_level(1, 40, 10), 10);
	expect_int("a real write becomes the last write", note_applied_level(0, 40, 10), 40);
	expect_int("dry-run fade continues from the simulated level",
		   fade_from_level(1, 80, 10, 100), 80);
	expect_int("dry-run fade stays once it reaches the target",
		   fade_from_level(1, 100, 10, 100), 100);
	expect_int("live fade starts from the last write",
		   fade_from_level(0, 80, 10, 100), 10);
	expect_int("fade with no level yet starts at the target",
		   fade_from_level(1, -1, -1, 40), 40);
	{
		int log = 1;
		int n = 0;
		int logs = 0;
		int i;

		for (i = 0; i < LUX_FAIL_BOUND + 5; i++) {
			n = lux_error_advance(n, LUX_FAIL_BOUND, &log);
			if (log)
				logs++;
		}
		expect_int("lux warnings are the first failure and the bound", logs, 2);
		expect_int("lux error count stops at the bound", n, LUX_FAIL_BOUND);
		n = lux_error_advance(n, LUX_FAIL_BOUND, &log);
		expect_int("a later lux failure stays quiet", log, 0);
		expect_int("the bounded fallback still applies",
			   lux_failure_action(1, n, LUX_FAIL_BOUND), LUX_FALLBACK);
	}
	{
		int last = note_applied_level(1, 40, 10);

		expect_int("dry-run does not invent a manual change",
			   manual_change_detected(10, last), 0);
		last = note_applied_level(0, 40, last);
		expect_int("readback of a real write is not manual",
			   manual_change_detected(40, last), 0);
	}
	expect_int("lux failure before the lamp follows waits", lux_failure_action(0, 1, LUX_FAIL_BOUND), LUX_WAIT);
	expect_int("lux failure holds the last sample", lux_failure_action(1, 1, LUX_FAIL_BOUND), LUX_HOLD);
	expect_int("repeated lux failure uses the bounded fallback",
		   lux_failure_action(1, LUX_FAIL_BOUND, LUX_FAIL_BOUND), LUX_FALLBACK);

	expect_near("manual fade is 350 ms", fade_duration(1), 0.350, 1e-12);
	expect_near("automatic fade is 500 ms", fade_duration(0), 0.500, 1e-12);
	memset(&fade, 0, sizeof fade);
	level = fade_level(&fade, 100, 0, 0.0, FADE_AUTO_S, &fading);
	expect_int("fade starts at the current level", level, 0);
	expect_int("fade is in progress", fading, 1);
	level = fade_level(&fade, 100, 0, 0.250, FADE_AUTO_S, &fading);
	expect_int("fade midpoint", level, 50);
	expect_int("fade still in progress", fading, 1);
	level = fade_level(&fade, 100, 50, 0.250, FADE_AUTO_S, &fading);
	expect_int("fade ends on the target", level, 100);
	expect_int("fade finished", fading, 0);

	expect_int("format state", format_state(buf, sizeof buf, -0.25, 1), 0);
	expect_int("parse state", parse_state(buf, &parsed, &muted), 0);
	expect_near("parsed offset", parsed, -0.25, 1e-8);
	expect_int("parsed mute", muted, 1);
	expect_int("reject a state with no mute", parse_state("offset 0.1\n", &parsed, &muted), -1);
}

static int self_test(void)
{
	test_lux_curve();
	test_lux_ema();
	test_display_fade();
	test_idle_fade();
	test_level();
	test_offset_mute_manual();
	if (failures) {
		fprintf(stderr, "self-test: %d failure%s\n", failures, failures == 1 ? "" : "s");
		return 1;
	}
	printf("self-test ok\n");
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: ct720-kbd-light [--dry-run] [--verbose] [--self-test] [--no-auto]\n"
		"                       [--idle-hold SEC|never] [--idle-fade SEC] [--wake-fade SEC]\n"
		"                       [--lux-override LUX]\n"
		"\n"
		"Drive /sys/class/leds/kbd_backlight from the CT720 lux sensor.\n"
		"A manual brightness change is remembered as an offset from the lux\n"
		"curve. Manual off stays off until the user raises it. Idle hold\n"
		"defaults to never, matching macOS. --no-auto keeps that manual level\n"
		"and applies only the idle fade. --dry-run does not write the LED.\n");
}

static int parse_double_arg(const char *s, double *out)
{
	char *end = NULL;
	double v;

	errno = 0;
	v = strtod(s, &end);
	if (!s[0] || end == s || *end || errno || v != v)
		return -1;
	*out = v;
	return 0;
}

static int parse_args(int argc, char **argv, struct config *cfg, int *self_test_flag)
{
	int i;

	memset(cfg, 0, sizeof *cfg);
	cfg->idle_never = 1;
	cfg->idle_hold = 10.0;
	cfg->idle_fade = 1.20;
	cfg->wake_fade = 0.30;
	*self_test_flag = 0;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *val = NULL;

		if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) {
			usage();
			return 2;
		}
		if (strcmp(a, "--verbose") == 0) {
			cfg->verbose = 1;
			continue;
		}
		if (strcmp(a, "--dry-run") == 0) {
			cfg->dry_run = 1;
			continue;
		}
		if (strcmp(a, "--no-auto") == 0) {
			cfg->no_auto = 1;
			continue;
		}
		if (strcmp(a, "--self-test") == 0) {
			*self_test_flag = 1;
			continue;
		}
		if (strncmp(a, "--idle-hold=", 12) == 0)
			val = a + 12;
		else if (strcmp(a, "--idle-hold") == 0 && i + 1 < argc)
			val = argv[++i];
		if (val && strncmp(a, "--idle-hold", 11) == 0) {
			if (strcmp(val, "never") == 0) {
				cfg->idle_never = 1;
				continue;
			}
			cfg->idle_never = 0;
			if (parse_double_arg(val, &cfg->idle_hold) || cfg->idle_hold < 0.0)
				goto bad;
			continue;
		}
		val = NULL;
		if (strncmp(a, "--idle-fade=", 12) == 0)
			val = a + 12;
		else if (strcmp(a, "--idle-fade") == 0 && i + 1 < argc)
			val = argv[++i];
		if (val && strncmp(a, "--idle-fade", 11) == 0) {
			if (parse_double_arg(val, &cfg->idle_fade) || cfg->idle_fade < 0.0)
				goto bad;
			continue;
		}
		val = NULL;
		if (strncmp(a, "--wake-fade=", 12) == 0)
			val = a + 12;
		else if (strcmp(a, "--wake-fade") == 0 && i + 1 < argc)
			val = argv[++i];
		if (val && strncmp(a, "--wake-fade", 11) == 0) {
			if (parse_double_arg(val, &cfg->wake_fade) || cfg->wake_fade < 0.0)
				goto bad;
			continue;
		}
		val = NULL;
		if (strncmp(a, "--lux-override=", 15) == 0)
			val = a + 15;
		else if (strcmp(a, "--lux-override") == 0 && i + 1 < argc)
			val = argv[++i];
		if (val && strncmp(a, "--lux-override", 14) == 0) {
			if (parse_double_arg(val, &cfg->lux_override) || cfg->lux_override < 0.0)
				goto bad;
			cfg->have_lux_override = 1;
			continue;
		}
		goto bad;
	}
	return 0;

bad:
	usage();
	return 2;
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
	if (end == s || errno || v != v)
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

static int open_retry(const char *path, int flags, int seconds)
{
	int fd = -1;
	int i;

	for (i = 0; i < seconds * 2; i++) {
		fd = open(path, flags | O_CLOEXEC);
		if (fd >= 0)
			return fd;
		if (errno != ENOENT)
			return -1;
		if (g_stop)
			return -1;
		nanosleep(&(struct timespec){ .tv_nsec = 500000000L }, NULL);
	}
	return -1;
}

static int ensure_trigger_none(int dry_run)
{
	char buf[512];

	if (read_path_text(KBD_TRIGGER_PATH, buf, sizeof buf)) {
		fprintf(stderr, "ct720-kbd-light: cannot read %s: %s\n", KBD_TRIGGER_PATH, strerror(errno));
		return -1;
	}
	if (strstr(buf, "[none]"))
		return 0;
	if (dry_run) {
		fprintf(stderr, "ct720-kbd-light: trigger is not none; dry-run will not change it\n");
		return 0;
	}
	{
		int fd = open(KBD_TRIGGER_PATH, O_WRONLY | O_CLOEXEC);

		if (fd < 0 || write_fd_text(fd, "none")) {
			fprintf(stderr, "ct720-kbd-light: cannot set trigger none: %s\n", strerror(errno));
			if (fd >= 0)
				close(fd);
			return -1;
		}
		close(fd);
	}
	return 0;
}

static int dpms_text_is_off(const char *s)
{
	while (*s == ' ' || *s == '\t')
		s++;
	if (strncasecmp(s, "on", 2) == 0 && (s[2] == '\0' || s[2] == '\n' || isspace((unsigned char)s[2])))
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

static void handle_event(struct input_src *src, const struct input_event *ev, int *activity, int *lid_closed)
{
	if (src->lid && ev->type == EV_SW && ev->code == SW_LID) {
		*lid_closed = ev->value != 0;
		if (ev->value == 0)
			*activity = 1;
	}
	if (src->activity && (ev->type == EV_KEY || ev->type == EV_ABS))
		*activity = 1;
	if (src->lid && ev->type == EV_KEY)
		*activity = 1;
}

static void drain_input(struct input_src *src, int *activity, int *lid_closed)
{
	for (;;) {
		ssize_t n;
		size_t off;

		if (src->fill >= sizeof src->buf)
			src->fill = 0;
		n = read(src->fd, src->buf + src->fill, sizeof src->buf - src->fill);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return;
		}
		if (n == 0)
			return;
		src->fill += (size_t)n;
		off = 0;
		while (src->fill - off >= sizeof(struct input_event)) {
			struct input_event ev;

			memcpy(&ev, src->buf + off, sizeof ev);
			off += sizeof ev;
			handle_event(src, &ev, activity, lid_closed);
		}
		if (off) {
			memmove(src->buf, src->buf + off, src->fill - off);
			src->fill -= off;
		}
	}
}

static int open_inputs(struct input_src *srcs, int *n_out, int *lid_closed)
{
	DIR *dir;
	struct dirent *ent;
	int n = 0;
	int activity_devs = 0;

	*lid_closed = 0;
	dir = opendir("/sys/class/input");
	if (!dir) {
		fprintf(stderr, "ct720-kbd-light: cannot list /sys/class/input: %s\n", strerror(errno));
		return -1;
	}

	while ((ent = readdir(dir))) {
		char name_path[512];
		char dev_path[320];
		char name[128];
		int fd;
		int is_kbd;
		int is_pad;
		int is_lid;

		if (strncmp(ent->d_name, "event", 5) != 0)
			continue;
		snprintf(name_path, sizeof name_path, "/sys/class/input/%s/device/name", ent->d_name);
		if (read_path_text(name_path, name, sizeof name))
			continue;
		name[strcspn(name, "\n")] = '\0';

		snprintf(dev_path, sizeof dev_path, "/dev/input/%s", ent->d_name);
		fd = open(dev_path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0) {
			if (errno == EACCES)
				fprintf(stderr, "ct720-kbd-light: cannot open %s (need root or group input)\n", dev_path);
			else
				fprintf(stderr, "ct720-kbd-light: cannot open %s: %s\n", dev_path, strerror(errno));
			closedir(dir);
			*n_out = n;
			return -1;
		}

		is_kbd = strcmp(name, KBD_INPUT_NAME) == 0;
		is_pad = strcmp(name, PAD_INPUT_NAME) == 0;
		is_lid = device_has_sw_lid(fd);
		if (!is_kbd && !is_pad && !is_lid) {
			close(fd);
			continue;
		}
		if (n >= MAX_INPUTS) {
			fprintf(stderr, "ct720-kbd-light: ignoring extra input %s\n", name);
			close(fd);
			continue;
		}
		memset(&srcs[n], 0, sizeof srcs[n]);
		srcs[n].fd = fd;
		srcs[n].activity = is_kbd || is_pad;
		srcs[n].lid = is_lid;
		snprintf(srcs[n].name, sizeof srcs[n].name, "%s", name);
		if (is_lid && lid_is_closed(fd))
			*lid_closed = 1;
		if (srcs[n].activity)
			activity_devs++;
		n++;
	}
	closedir(dir);
	*n_out = n;
	if (!activity_devs) {
		fprintf(stderr, "ct720-kbd-light: no %s or %s input\n", KBD_INPUT_NAME, PAD_INPUT_NAME);
		return -1;
	}
	return 0;
}

static void close_inputs(struct input_src *srcs, int n)
{
	int i;

	for (i = 0; i < n; i++) {
		if (srcs[i].fd >= 0)
			close(srcs[i].fd);
		srcs[i].fd = -1;
	}
}

/* 1 = wrote the CT720 illuminance path, 0 = other iio devices only,
 * -1 = no iio device could be named. Does not open the illuminance node. */
static int find_ct720_lux_path(char *path, size_t cap)
{
	DIR *dir;
	struct dirent *ent;
	int other = 0;

	dir = opendir(IIO_DEVICES);
	if (!dir)
		return -1;
	while ((ent = readdir(dir)) != NULL) {
		char name_path[512];
		char name[128];

		if (strncmp(ent->d_name, "iio:device", 10) != 0)
			continue;
		if (snprintf(name_path, sizeof name_path, "%s/%s/name",
			     IIO_DEVICES, ent->d_name) >= (int)sizeof name_path)
			continue;
		if (read_path_text(name_path, name, sizeof name))
			continue;
		name[strcspn(name, "\n")] = '\0';
		if (strcmp(name, CT720_IIO_NAME) != 0) {
			other = 1;
			continue;
		}
		if (snprintf(path, cap, "%s/%s/in_illuminance_input",
			     IIO_DEVICES, ent->d_name) >= (int)cap) {
			closedir(dir);
			return -1;
		}
		closedir(dir);
		return 1;
	}
	closedir(dir);
	return other ? 0 : -1;
}

/* Retries while no iio device is named yet. A definite non-CT720 scan
 * returns immediately so the wrong machine is not polled for the whole wait. */
static int wait_ct720_lux_path(char *path, size_t cap, int seconds)
{
	int i;
	int kind = -1;

	for (i = 0; i < seconds * 2; i++) {
		kind = find_ct720_lux_path(path, cap);
		if (kind == 1 || kind == 0)
			return kind;
		if (g_stop)
			return -1;
		nanosleep(&(struct timespec){ .tv_nsec = 500000000L }, NULL);
	}
	return kind;
}

static int save_state(double offset, int muted)
{
	char body[128];
	char tmp[160];
	int fd;
	size_t len;
	ssize_t n;

	if (format_state(body, sizeof body, offset, muted))
		return -1;
	if (snprintf(tmp, sizeof tmp, "%s.tmp", OFFSET_PATH) >= (int)sizeof tmp)
		return -1;
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd < 0)
		return -1;
	len = strlen(body);
	n = write(fd, body, len);
	if (n < 0 || (size_t)n != len || fsync(fd)) {
		int err = errno;

		close(fd);
		unlink(tmp);
		errno = err;
		return -1;
	}
	if (close(fd)) {
		unlink(tmp);
		return -1;
	}
	if (rename(tmp, OFFSET_PATH)) {
		int err = errno;

		unlink(tmp);
		errno = err;
		return -1;
	}
	return 0;
}

static int load_state(double *offset, int *muted)
{
	char buf[256];

	if (read_path_text(OFFSET_PATH, buf, sizeof buf))
		return -1;
	return parse_state(buf, offset, muted);
}

static int run_daemon(const struct config *cfg)
{
	int lux_fd = -1;
	int kbd_fd = -1;
	int panel_actual_fd = -1;
	int panel_max_fd = -1;
	int panel_power_fd = -1;
	int dpms_fd = -1;
	int timer_fd = -1;
	int max_brightness = 255;
	int last_level = -1;
	int last_written = -1;
	int fading = 0;
	int manual_fade = 0;
	int muted = 0;
	int manual_seeded = 0;
	int write_errors = 0;
	int lux_errors = 0;
	int lux_driving = 0;
	char lux_path[512];
	double offset = 0.0;
	double manual_frac = 1.0;
	double pause_until = 0.0;
	struct level_fade fade;
	int have_panel_actual = 0;
	int have_panel_max = 0;
	int have_bl_power = 0;
	int panel_actual = 0;
	int panel_max = 1;
	int bl_power = 0;
	int dpms_off = 0;
	int lid_closed = 0;
	int ninputs = 0;
	int pending_activity = 0;
	double last_status = 0.0;
	double last_now = 0.0;
	char dpms_path[512];
	struct lux_ema ema;
	struct display_fade display;
	struct idle_fade idle;
	struct input_src inputs[MAX_INPUTS];
	struct pollfd pfds[1 + MAX_INPUTS];
	struct itimerspec spec;
	int i;
	int rc = 1;

	memset(&ema, 0, sizeof ema);
	memset(&display, 0, sizeof display);
	memset(&idle, 0, sizeof idle);
	memset(&fade, 0, sizeof fade);
	memset(inputs, 0, sizeof inputs);
	dpms_path[0] = '\0';
	lux_path[0] = '\0';

	/* Not this machine: leave whatever backlight it has alone. The CT720
	 * is whichever iio device is named aop-sensors-als, not device0. */
	if (!cfg->have_lux_override) {
		int kind = find_ct720_lux_path(lux_path, sizeof lux_path);
		int kbd_there = access(KBD_BRIGHT_PATH, F_OK) == 0;

		if (kind == 0) {
			fprintf(stderr,
				"ct720-kbd-light: iio devices are present but none is %s; nothing to do\n",
				CT720_IIO_NAME);
			return 0;
		}
		if (kind != 1 && !kbd_there) {
			fprintf(stderr,
				"ct720-kbd-light: no CT720 lux sensor or kbd_backlight; nothing to do\n");
			return 0;
		}
		if (kind != 1)
			kind = wait_ct720_lux_path(lux_path, sizeof lux_path, 20);
		if (kind == 0) {
			fprintf(stderr,
				"ct720-kbd-light: iio devices are present but none is %s; nothing to do\n",
				CT720_IIO_NAME);
			return 0;
		}
		if (kind != 1) {
			fprintf(stderr, "ct720-kbd-light: no CT720 lux sensor; nothing to do\n");
			return 0;
		}
		lux_fd = open_retry(lux_path, O_RDONLY, 20);
		if (lux_fd < 0) {
			int err = errno;

			if (err == ENOENT) {
				fprintf(stderr, "ct720-kbd-light: no CT720 lux sensor; nothing to do\n");
				rc = 0;
				goto out;
			}
			fprintf(stderr, "ct720-kbd-light: cannot open %s: %s\n", lux_path, strerror(err));
			goto out;
		}
	}
	kbd_fd = open_retry(KBD_BRIGHT_PATH, cfg->dry_run ? O_RDONLY : O_RDWR, 20);
	if (kbd_fd < 0) {
		int err = errno;

		if (err == ENOENT) {
			fprintf(stderr, "ct720-kbd-light: no kbd_backlight; nothing to do\n");
			rc = 0;
			goto out;
		}
		fprintf(stderr, "ct720-kbd-light: cannot open %s: %s\n", KBD_BRIGHT_PATH, strerror(err));
		goto out;
	}
	{
		int max_fd = open(KBD_MAX_PATH, O_RDONLY | O_CLOEXEC);

		if (max_fd < 0 || read_fd_int(max_fd, &max_brightness) || max_brightness <= 0) {
			fprintf(stderr, "ct720-kbd-light: cannot read %s: %s\n", KBD_MAX_PATH, strerror(errno));
			if (max_fd >= 0)
				close(max_fd);
			goto out;
		}
		close(max_fd);
	}
	if (ensure_trigger_none(cfg->dry_run))
		goto out;

	panel_actual_fd = open(PANEL_ACTUAL_PATH, O_RDONLY | O_CLOEXEC);
	panel_max_fd = open(PANEL_MAX_PATH, O_RDONLY | O_CLOEXEC);
	panel_power_fd = open(PANEL_POWER_PATH, O_RDONLY | O_CLOEXEC);
	if (find_edp_dpms(dpms_path, sizeof dpms_path) == 0)
		dpms_fd = open(dpms_path, O_RDONLY | O_CLOEXEC);

	if (open_inputs(inputs, &ninputs, &lid_closed))
		goto out;

	timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	if (timer_fd < 0) {
		fprintf(stderr, "ct720-kbd-light: timerfd: %s\n", strerror(errno));
		goto out;
	}
	memset(&spec, 0, sizeof spec);
	spec.it_interval.tv_nsec = (long)(TICK_S * 1e9);
	spec.it_value.tv_nsec = spec.it_interval.tv_nsec;
	if (timerfd_settime(timer_fd, 0, &spec, NULL)) {
		fprintf(stderr, "ct720-kbd-light: timerfd_settime: %s\n", strerror(errno));
		goto out;
	}

	if (access(OFFSET_PATH, R_OK) == 0) {
		if (load_state(&offset, &muted))
			fprintf(stderr, "ct720-kbd-light: ignoring unreadable %s\n", OFFSET_PATH);
		else if (muted)
			manual_frac = 0.0;
	}

	{
		char hold_text[32];

		if (cfg->idle_never)
			snprintf(hold_text, sizeof hold_text, "never");
		else
			snprintf(hold_text, sizeof hold_text, "%.1fs", cfg->idle_hold);
		fprintf(stderr,
			"ct720-kbd-light: %sCT720 -> kbd_backlight (max %d), idle hold %s fade %.1fs%s%s%s\n",
			cfg->dry_run ? "dry-run " : "",
			max_brightness, hold_text, cfg->idle_fade,
			cfg->have_lux_override ? ", lux override" : "",
			cfg->no_auto ? ", manual hold" : "",
			muted ? ", muted" : "");
	}
	for (i = 0; i < ninputs; i++)
		fprintf(stderr, "ct720-kbd-light: input %s%s%s\n", inputs[i].name,
			inputs[i].activity ? " activity" : "",
			inputs[i].lid ? " lid" : "");
	if (dpms_fd >= 0)
		fprintf(stderr, "ct720-kbd-light: dpms %s\n", dpms_path);
	else
		fprintf(stderr, "ct720-kbd-light: no internal-panel dpms node; blanking uses bl_power and brightness\n");

	last_now = mono_now();
	while (!g_stop) {
		int activity = pending_activity;
		int ready;
		int level;
		double now;
		double dt;
		double sample;
		double amb;
		double panel_frac;
		uint64_t expirations;
		int poll_n;
		int pr;

		pending_activity = 0;
		pfds[0].fd = timer_fd;
		pfds[0].events = POLLIN;
		pfds[0].revents = 0;
		poll_n = 1;
		for (i = 0; i < ninputs; i++) {
			pfds[poll_n].fd = inputs[i].fd;
			pfds[poll_n].events = POLLIN;
			pfds[poll_n].revents = 0;
			poll_n++;
		}
		pr = poll(pfds, (nfds_t)poll_n, 1000);
		if (pr < 0) {
			if (errno == EINTR) {
				pending_activity = activity;
				continue;
			}
			fprintf(stderr, "ct720-kbd-light: poll: %s\n", strerror(errno));
			goto out;
		}

		for (i = 0; i < ninputs; i++) {
			if (pfds[i + 1].revents & (POLLERR | POLLHUP | POLLNVAL)) {
				fprintf(stderr, "ct720-kbd-light: input %s closed\n", inputs[i].name);
				goto out;
			}
			if (pfds[i + 1].revents & POLLIN)
				drain_input(&inputs[i], &activity, &lid_closed);
		}
		if (!(pfds[0].revents & POLLIN)) {
			pending_activity = activity;
			continue;
		}
		if (read(timer_fd, &expirations, sizeof expirations) < 0 && errno != EAGAIN) {
			pending_activity = activity;
			continue;
		}
		(void)expirations;

		now = mono_now();
		dt = now - last_now;
		if (dt < 0.0)
			dt = 0.0;
		if (dt > 1.0)
			dt = 1.0;
		last_now = now;

		if (cfg->have_lux_override) {
			sample = cfg->lux_override;
			ready = lux_ema_step(&ema, sample, dt, 0.0, 0.0);
			lux_errors = 0;
			if (ready)
				lux_driving = 1;
		} else if (read_fd_double(lux_fd, &sample) == 0) {
			lux_errors = 0;
			ready = lux_ema_step(&ema, sample, dt, LUX_EMA_TAU, LUX_BRIGHT_WINDOW);
			if (ready)
				lux_driving = 1;
		} else {
			int action;
			int log_lux = 0;

			lux_errors = lux_error_advance(lux_errors, LUX_FAIL_BOUND, &log_lux);
			action = lux_failure_action(lux_driving, lux_errors, LUX_FAIL_BOUND);
			if (log_lux && lux_errors == 1)
				fprintf(stderr, "ct720-kbd-light: lux read failed: %s\n", strerror(errno));
			else if (log_lux && lux_errors == LUX_FAIL_BOUND)
				fprintf(stderr,
					"ct720-kbd-light: lux read failed %d times; holding the last lux while panel, lid, and idle still apply\n",
					lux_errors);
			if (action == LUX_WAIT) {
				pending_activity = activity;
				continue;
			}
			ready = 1;
		}
		if (!ready) {
			pending_activity = activity;
			continue;
		}

		if (panel_actual_fd >= 0 && read_fd_int(panel_actual_fd, &panel_actual) == 0)
			have_panel_actual = 1;
		if (panel_max_fd >= 0 && read_fd_int(panel_max_fd, &panel_max) == 0 && panel_max > 0)
			have_panel_max = 1;
		if (panel_power_fd >= 0 && read_fd_int(panel_power_fd, &bl_power) == 0)
			have_bl_power = 1;
		if (dpms_fd >= 0) {
			char text[32];

			if (read_fd_text(dpms_fd, text, sizeof text) == 0)
				dpms_off = dpms_text_is_off(text);
		}

		if (lid_closed || (dpms_fd >= 0 && dpms_off) || (have_bl_power && bl_power != 0)) {
			panel_frac = -1.0;
		} else if (have_panel_actual && have_panel_max) {
			if (panel_actual <= 0)
				panel_frac = 0.0;
			else
				panel_frac = clamp01((double)panel_actual / (double)panel_max);
		} else {
			panel_frac = 1.0;
		}

		amb = lux_to_fraction(ema.v);
		display_fade_step(&display, panel_frac, dt);
		if (cfg->idle_never) {
			if (!idle.inited) {
				idle.inited = 1;
				idle.gain = 1.0;
				idle.last_activity = now;
			}
			idle.gain = 1.0;
			if (activity)
				idle.last_activity = now;
		} else {
			idle_fade_step(&idle, now, activity, dt, cfg->idle_hold, cfg->idle_fade, cfg->wake_fade);
		}

		{
			int observed = -1;

			if (read_fd_int(kbd_fd, &observed) == 0) {
				if (!manual_seeded && max_brightness > 0) {
					if (cfg->no_auto && !muted)
						manual_frac = (double)observed / (double)max_brightness;
					manual_seeded = 1;
				}
				/* The level already on the LED is not a manual change. */
				if (last_written < 0) {
					last_written = observed;
					last_level = observed;
				}
				if (!cfg->dry_run && manual_change_detected(observed, last_written)) {
					offset = offset_from_manual(observed, max_brightness, amb);
					muted = observed == 0;
					manual_frac = max_brightness > 0
						? (double)observed / (double)max_brightness : 0.0;
					last_written = observed;
					last_level = observed;
					pause_until = now + MANUAL_PAUSE_S;
					manual_fade = 1;
					fading = 0;
					fade.active = 0;
					if (!cfg->dry_run && save_state(offset, muted))
						fprintf(stderr, "ct720-kbd-light: cannot save offset: %s\n",
							strerror(errno));
					fprintf(stderr,
						"ct720-kbd-light: manual level %d offset %.3f%s\n",
						observed, offset, muted ? " muted" : "");
				}
			}
		}

		{
			double frac = applied_fraction(amb, offset, display.gain, idle.gain,
						       muted, cfg->no_auto, manual_frac);
			int target = level_from(frac, 1.0, 1.0, max_brightness);

			if (now < pause_until) {
				level = last_written >= 0 ? last_written : target;
			} else {
				int from = fade_from_level(cfg->dry_run, last_level,
							    last_written, target);
				double dur = fade_duration(manual_fade);

				level = fade_level(&fade, target, from, dt, dur, &fading);
				if (!fading && level == target)
					manual_fade = 0;
			}
		}

		if (now >= pause_until && level != last_level) {
			if (!cfg->dry_run) {
				if (write_fd_int(kbd_fd, level)) {
					write_errors++;
					fprintf(stderr, "ct720-kbd-light: brightness write %d failed: %s\n",
						level, strerror(errno));
					if (write_errors >= 20)
						goto out;
					continue;
				}
				write_errors = 0;
			}
			last_written = note_applied_level(cfg->dry_run, level, last_written);
			if (cfg->verbose || (level == 0) != (last_level == 0) || last_level < 0) {
				fprintf(stderr,
					"ct720-kbd-light:%s level %d (lux %.1f amb %.3f off %.3f disp %.3f idle %.3f%s)\n",
					cfg->dry_run ? " dry-run" : "",
					level, ema.v, amb, offset, display.gain, idle.gain,
					muted ? " muted" : "");
			}
			last_level = level;
		} else if (cfg->verbose && now - last_status >= 2.0) {
			fprintf(stderr,
				"ct720-kbd-light: status lux %.1f panel %d/%d dpms %s bl %d lid %s idle %.1fs -> %d\n",
				ema.v,
				have_panel_actual ? panel_actual : -1,
				have_panel_max ? panel_max : -1,
				dpms_fd < 0 ? "n/a" : (dpms_off ? "off" : "on"),
				have_bl_power ? bl_power : -1,
				lid_closed ? "closed" : "open",
				cfg->idle_never ? 0.0 : now - idle.last_activity,
				level);
			last_status = now;
		}
	}

	rc = 0;
	fprintf(stderr, "ct720-kbd-light: stopping\n");

out:
	if (timer_fd >= 0)
		close(timer_fd);
	close_inputs(inputs, ninputs);
	if (dpms_fd >= 0)
		close(dpms_fd);
	if (panel_power_fd >= 0)
		close(panel_power_fd);
	if (panel_max_fd >= 0)
		close(panel_max_fd);
	if (panel_actual_fd >= 0)
		close(panel_actual_fd);
	if (kbd_fd >= 0)
		close(kbd_fd);
	if (lux_fd >= 0)
		close(lux_fd);
	return rc;
}

int main(int argc, char **argv)
{
	struct config cfg;
	int do_self_test = 0;
	int parsed;
	struct sigaction sa;

	parsed = parse_args(argc, argv, &cfg, &do_self_test);
	if (parsed)
		return parsed == 2 ? 2 : parsed;
	if (do_self_test)
		return self_test();

	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	return run_daemon(&cfg);
}
