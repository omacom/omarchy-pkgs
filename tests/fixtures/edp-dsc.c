/* Hardware helpers are deliberately stubbed; only the extracted policy runs. */
#include <assert.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

struct drm_display_mode { int crtc_clock, crtc_htotal; };
struct intel_crtc_state {
	struct { struct drm_display_mode adjusted_mode; } hw;
	int pipe_bpp, port_clock, lane_count;
	bool fec_enable;
	struct {
		bool compression_enable, compression_enabled_on_link;
		int compressed_bpp_x16, slice_config, config;
	} dsc;
};
struct intel_display { void *drm; } fake_display;
struct intel_connector {} fake_connector;
struct intel_dp { bool force_dsc_en; } dp;
struct intel_encoder {} encoder;
struct drm_connector_state { void *connector; } conn;
struct link_config_limits { struct { int max_bpp; } pipe; };
static bool edp, caps, joiner;
static int depth, maximum, fail, calls;

#define to_intel_display(x) (&fake_display)
#define to_intel_connector(x) (&fake_connector)
#define enc_to_intel_dp(x) (&dp)
#define intel_crtc_num_joined_pipes(x) 1
#define intel_dp_joiner_needs_dsc(d, n) (joiner)
#define intel_dp_is_edp(x) (edp)
#define intel_dp_is_uhbr(x) false
#define intel_dp_supports_dsc(a, b, c) (caps)
#define intel_dp_mtp_tu_compute_config(...) 0
#define fxp_q4_from_int(x) ((x) * 16)
#define drm_dbg_kms(...) ((void)0)
#define FXP_Q4_FMT "%d"
#define intel_dsc_line_slice_count(x) (*(x))

static void intel_dp_dsc_reset_config(struct intel_crtc_state *s)
{
	s->fec_enable = false;
	s->dsc.compression_enable = false;
	s->dsc.compressed_bpp_x16 = 0;
	s->dsc.slice_config = 0;
	s->dsc.config = 0;
	/* Match the current helper: compression_enabled_on_link is not reset. */
}

static bool intel_dp_compute_config_limits(struct intel_dp *d,
	struct drm_connector_state *c, struct intel_crtc_state *s,
	bool r, bool compression, struct link_config_limits *l)
{
	l->pipe.max_bpp = compression ? s->pipe_bpp : maximum;
	return !(compression && fail == 1);
}

static int intel_dp_compute_link_config_wide(struct intel_dp *d,
	struct intel_crtc_state *s, struct drm_connector_state *c,
	struct link_config_limits *l)
{
	s->pipe_bpp = depth;
	s->port_clock = 540000;
	s->lane_count = 4;
	return fail == 4 ? -EINVAL : 0;
}

static int intel_dp_dsc_compute_config(struct intel_dp *d,
	struct intel_crtc_state *s, struct drm_connector_state *c,
	struct link_config_limits *l, int slots)
{
	calls++;
	s->pipe_bpp = l->pipe.max_bpp;
	s->port_clock = 270000;
	s->lane_count = 2;
	/* Mutate all saved fields to make incomplete restoration observable. */
	s->fec_enable = true;
	s->dsc.compressed_bpp_x16 = 128;
	s->dsc.slice_config = 4;
	s->dsc.config = 123;
	if (fail == 2)
		return -EINVAL;
	s->dsc.compression_enable = true;
	s->dsc.compression_enabled_on_link = true;
	return 0;
}

static bool intel_dp_dotclk_valid(struct intel_display *d,
	int c, int t, int slices, int pipes)
{
	return !(slices && fail == 3);
}

/* EXTRACTED_FUNCTION */

int main(int argc, char **argv)
{
	const char *names[] = {
		"prefer DSC and restore requested depth",
		"do not prefer DSC on external DP",
		"keep uncompressed 8 bpc",
		"keep uncompressed mode without DSC support",
		"respect the permitted input depth",
		"restore after invalid DSC limits",
		"restore after DSC computation failure",
		"restore after late dotclock rejection",
		"propagate required DSC computation failure",
		"reject a mode requiring unsupported DSC",
	};
	bool late_only = argc == 2 && !strcmp(argv[1], "late-dotclock");
	struct intel_crtc_state s;

	assert(argc == 1 || late_only);
	for (int test = late_only ? 7 : 0; test < (late_only ? 8 : 10); test++) {
		memset(&s, 0, sizeof(s));
		s.pipe_bpp = 30;
		edp = true;
		caps = true;
		joiner = false;
		depth = 18;
		maximum = 30;
		fail = 0;
		calls = 0;
		dp.force_dsc_en = false;
		if (test == 1)
			edp = false;
		if (test == 2)
			depth = 24;
		if (test == 3)
			caps = false;
		if (test == 4) {
			maximum = 18;
			s.pipe_bpp = 18;
		}
		if (test >= 5 && test <= 7)
			fail = test - 4;
		if (test == 8) {
			dp.force_dsc_en = true;
			fail = 2;
		}
		if (test == 9) {
			fail = 4;
			caps = false;
		}
		int ret = intel_dp_compute_link_for_joined_pipes(&encoder, &s, &conn, true);

		if (test == 8 || test == 9) {
			assert(ret == -EINVAL);
			assert(calls == (test == 8 ? 1 : 0));
		} else if (test == 0) {
			assert(ret == 0);
			assert(calls == 1);
			assert(s.pipe_bpp == 30);
			assert(s.dsc.compression_enable);
			assert(s.dsc.compression_enabled_on_link);
		} else {
			assert(ret == 0);
			assert(s.pipe_bpp == depth);
			assert(s.port_clock == 540000);
			assert(s.lane_count == 4);
			assert(!s.fec_enable);
			assert(!s.dsc.compression_enable);
			assert(!s.dsc.compression_enabled_on_link);
			assert(!s.dsc.compressed_bpp_x16);
			assert(!s.dsc.slice_config);
			assert(!s.dsc.config);
			assert(calls == (test == 6 || test == 7 ? 1 : 0));
		}
		printf("PASS: %s\n", names[test]);
	}
	return 0;
}
