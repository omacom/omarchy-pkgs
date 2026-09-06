// SPDX-License-Identifier: MIT
//
// hp-elitebook-x-g2i-camera-lc — HP EliteBook X G2i webcam daemon, libcamera route.
//
// Replaces the ffmpeg userspace ISP in /usr/bin/hp-elitebook-x-g2i-camera with
// libcamera's "simple" pipeline handler and its GPU software ISP, while keeping
// every behaviour of that daemon that exists because someone hit the bug it
// prevents. Read /usr/bin/hp-elitebook-x-g2i-camera first; it is the
// specification, and the comments below only record where this differs.
//
//   ov05c10 -> CSI2 -> ISYS (raw Bayer) -> libcamera softISP (GPU debayer, BLC,
//   AWB, CCM, gamma) -> XRGB8888 -> crop+scale+NV12 (libswscale) -> v4l2loopback
//
// THE TWO COUPLED CONSTRAINTS, unchanged from the bash daemon:
//
//   1. Chrome only enumerates a V4L2 device that advertises CAPTURE *without*
//      OUTPUT. v4l2loopback does that only while a writer holds the output
//      token (v4l2loopback.c vidioc_querycap(): with announce_all_caps=0 it
//      reports OUTPUT while has_output_token() is true, CAPTURE once a writer
//      has taken it). The token is taken by the first write() via
//      start_fileio(). So this daemon opens the loopback once at startup, keeps
//      it open for its whole life, and never stops writing frames into it —
//      even with the sensor powered down.
//
//   2. The privacy LED follows the SENSOR. So the sensor must be stopped and
//      released whenever no consumer is reading the loopback, or the LED is lit
//      from login onwards and users correctly read that as spying.
//
// WHAT CHANGED, and why it is safe. The bash daemon could not generate frames
// itself, so it needed a persistent ffmpeg writer fed from a FIFO, and swapped
// what fed the FIFO. A raw NV12 FIFO has no frame boundaries, so a feeder
// killed mid-frame desynced the stream permanently (torn image, green/magenta
// bands). Every one of the 42 lines of flag files, "let it finish the current
// frame" waits and kill_by_comm() in that daemon exists to avoid that.
//
// Here there is no FIFO and no second process. One function, writeFrame(),
// writes one whole frame per write(2) under one mutex, and it is the only thing
// that ever touches the loopback fd. v4l2loopback's write handler copies
// min(count, buffer_size) into exactly one buffer and marks it done
// (v4l2loopback.c v4l2_loopback_write()), so a write of exactly sizeimage bytes
// is one frame, atomically. A partial frame cannot be produced, in either
// switch direction, because there is no code path that writes less than a
// frame. The idle->active and active->idle transitions therefore need no
// synchronisation beyond "camera->stop() has returned", which libcamera
// guarantees means no further completion callbacks.
//
// SENSOR MODE. Do not ask libcamera for 1920x1080. SimpleCameraConfiguration::
// validate() picks "the smallest sensor resolution that can accommodate all
// streams without upscaling", which for 1920x1080 is the 2800x1576 mode. That
// mode never delivers a buffer on this machine and wedges the ISYS node (two
// hard wedges paid for that lesson). Request the native 2888x1808 mode and do
// the downscale here.
//
// V2: TWO ENGINES, ONE CONTRACT. Everything above still holds. What 2.0.0
// changes is where active-state frames come from; the loopback fd, the black
// idle frames, the consumer polling and the LED rules are byte-identical.
//
//   Engine A, "camhal" (default): Intel's hardware ISP through the pinned
//   CamHAL runtime in /usr/lib/hp-elitebook-x-g2i-camhal (HAL + bins release
//   set 20260327_1, icamerasrc 94e99776 — the pairing intel/ipu7-camera-hal#48
//   reports working with this sensor; newer tags are the broken ones). When a
//   consumer appears the daemon spawns
//
//     gst-launch-1.0 -q icamerasrc device-name=ov05c10-uf
//       ! video/x-raw,format=NV12,width=W,height=H ! fdsink fd=3
//
//   with LD_LIBRARY_PATH / GST_PLUGIN_PATH / CAMERA_CFG_PATH pointing into
//   that prefix, and relays frames from the pipe into writeFrame(). CamHAL
//   only ever sees a pipe; the daemon still owns the loopback and its format.
//   Frames travel on fd 3, not stdout, because CamHAL logs to stdout and one
//   stray log line in a raw NV12 stream desyncs every frame after it.
//
//   icamerasrc's buffers are the HAL's frame size, not GStreamer's: NV12 is
//   laid out at stride ALIGN64(W) with a tail of max(ALIGN64(W)*3/2, 1024)
//   spare bytes for PSYS (CameraUtils::getFrameSize() in the pinned HAL;
//   measured 3113280 per 1920x1080 frame against GStreamer's 3110400). The
//   reader consumes exactly one such chunk per frame and forwards only the
//   payload, so the loopback keeps receiving whole, exact-sizeimage frames.
//
//   2.0.2: HPCAM_DENOISE > 0 (default 8) inserts a temporal denoise stage
//   between icamerasrc and fdsink:
//
//     ! vapostproc denoise=N ! video/x-raw,format=NV12,width=W,height=H
//
//   vapostproc is the SYSTEM gst-plugin-va, not the pinned runtime:
//   GST_PLUGIN_PATH is additive, so it and the prefix's icamerasrc load into
//   one pipeline, and the prefix ships no GStreamer core libs for
//   LD_LIBRARY_PATH to shadow (both verified with gst-inspect-1.0 under the
//   child's exact environment). It runs the Intel GPU's VEBOX fixed-function
//   motion-adaptive filter via /dev/dri/renderD* — no LIBVA_* variables, near
//   zero CPU — which is the measured fix for the residual temporally-white
//   4-16px noise blobs the ISP leaves behind. THE READER CONTRACT MOVES WITH
//   THE FILTER: fdsink is then fed by vapostproc, whose buffers are packed
//   NV12 at the negotiated caps, exactly W*H*3/2 — no HAL stride, no spare
//   tail — so camhalChunkSize() is conditional on the filter being present.
//   HPCAM_DENOISE=0 removes the element and restores the 2.0.1 pipeline and
//   chunk math byte-identically. HPCAM_EXPOSURE_RANGE / HPCAM_GAIN_RANGE
//   ("min~max") pass through as icamerasrc properties to clamp its AE; unset
//   means the HAL's own limits.
//
//   Engine B, "softisp": the libcamera path below, unchanged. It takes over
//   for the rest of the boot after two consecutive CamHAL failures (process
//   exit, no first frame, frame stall), recorded in a /run flag so a
//   Restart=always crash loop cannot re-wedge CamHAL every five seconds. A
//   failed CamHAL process gets SIGKILL and never SIGTERM: a TERM'd CamHAL
//   keeps the IPU7 device nodes open and poisons every later attempt
//   (recovery-ladder record, 2026-08-05/06).
//
//   HPCAM_ENGINE=camhal|softisp overrides the default. An explicit camhal
//   also ignores the fallback flag and never falls back — that is the
//   debugging mode. Engine B's libcamera is initialised lazily, on first use:
//   the simple pipeline handler opens every media-graph entity while
//   enumerating, and two ISP stacks holding IPU7 nodes at once is exactly the
//   kind of sharing this hardware punishes.
//
//   AIQB OVERRIDE. The runtime package ships the stock Intel Linux tuning
//   (OV05C10_CJFPE50_PTL.aiqb, 779,910 bytes). A better-measured tuning exists
//   (extracted from HP's Windows driver) but cannot be redistributed, so it is
//   a local drop-in: if /etc/hp-elitebook-x-g2i/OV05C10_CJFPE50_PTL.aiqb is a
//   regular file at engine start, the daemon copies the whole config dir into
//   the unit's RuntimeDirectory, overlays that file, and points
//   CAMERA_CFG_PATH at the copy. A copy, not a symlink farm: the HAL walks the
//   dir with readdir and this keeps the overlay byte-for-byte the layout the
//   prefix was proven with. 4.1 MB into tmpfs per sensor start is noise. The
//   overlay is rebuilt on every start, so dropping the file in (or deleting
//   it) takes effect on the next camera use, no restart needed.

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <linux/media.h>
#include <linux/videodev2.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <libcamera/libcamera.h>

extern "C" {
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}

extern char **environ;

using namespace libcamera;

namespace {

/* ------------------------------------------------------------------ logging */

void logv(const char *fmt, va_list ap)
{
	char stamp[16];
	time_t t = time(nullptr);
	struct tm tm;
	localtime_r(&t, &tm);
	strftime(stamp, sizeof(stamp), "%H:%M:%S", &tm);
	fprintf(stderr, "%s ", stamp);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	fflush(stderr);
}

void logf(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	logv(fmt, ap);
	va_end(ap);
}

/* --------------------------------------------------------------- environment */

std::string envStr(const char *name, const std::string &def)
{
	const char *v = getenv(name);
	return (v && *v) ? std::string(v) : def;
}

long envLong(const char *name, long def)
{
	const char *v = getenv(name);
	if (!v || !*v)
		return def;
	char *end = nullptr;
	long r = strtol(v, &end, 10);
	if (end == v)
		return def;
	return r;
}

double envDouble(const char *name, double def)
{
	const char *v = getenv(name);
	if (!v || !*v)
		return def;
	char *end = nullptr;
	double r = strtod(v, &end);
	if (end == v)
		return def;
	return r;
}

bool envHas(const char *name)
{
	const char *v = getenv(name);
	return v && *v;
}

uint64_t monoMs()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return uint64_t(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

/* ------------------------------------------------------- config dir staging
 *
 * Plain recursive copy/remove for the aiqb-override overlay (see the header).
 * The CamHAL config dir is regular files in two levels of subdirectory, and
 * this deliberately handles exactly that: directories and regular files,
 * nothing else. It stages into the unit's private RuntimeDirectory, so there
 * are no hostile symlinks to defend against.
 */

bool copyFile(const std::string &src, const std::string &dst)
{
	int in = open(src.c_str(), O_RDONLY | O_CLOEXEC);
	if (in < 0)
		return false;
	int out = open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (out < 0) {
		close(in);
		return false;
	}
	char buf[65536];
	bool ok = true;
	for (;;) {
		ssize_t n = read(in, buf, sizeof(buf));
		if (n == 0)
			break;
		if (n < 0) {
			if (errno == EINTR)
				continue;
			ok = false;
			break;
		}
		char *p = buf;
		while (n > 0) {
			ssize_t w = write(out, p, n);
			if (w < 0) {
				if (errno == EINTR)
					continue;
				ok = false;
				break;
			}
			p += w;
			n -= w;
		}
		if (!ok)
			break;
	}
	close(in);
	if (close(out) < 0)
		ok = false;
	return ok;
}

bool copyTree(const std::string &src, const std::string &dst)
{
	if (mkdir(dst.c_str(), 0755) < 0 && errno != EEXIST)
		return false;
	DIR *d = opendir(src.c_str());
	if (!d)
		return false;
	bool ok = true;
	while (struct dirent *e = readdir(d)) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		std::string s = src + "/" + e->d_name;
		std::string t = dst + "/" + e->d_name;
		struct stat st;
		if (stat(s.c_str(), &st) < 0) {
			ok = false;
			break;
		}
		if (S_ISDIR(st.st_mode))
			ok = copyTree(s, t);
		else if (S_ISREG(st.st_mode))
			ok = copyFile(s, t);
		/* anything else: skip silently, the config dir has none */
		if (!ok)
			break;
	}
	closedir(d);
	return ok;
}

void removeTree(const std::string &path)
{
	DIR *d = opendir(path.c_str());
	if (d) {
		while (struct dirent *e = readdir(d)) {
			if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
				continue;
			std::string p = path + "/" + e->d_name;
			struct stat st;
			if (lstat(p.c_str(), &st) < 0)
				continue;
			if (S_ISDIR(st.st_mode))
				removeTree(p);
			else
				unlink(p.c_str());
		}
		closedir(d);
	}
	rmdir(path.c_str());
}

/* ------------------------------------------------------- media graph probing
 *
 * Nothing below configures anything: libcamera's simple pipeline handler owns
 * the media graph (it calls MediaDevice::disableLinks() and re-enables the path
 * on every configure(), which is why the bash daemon's "re-enable the link or
 * VIDIOC_STREAMON returns ENOLINK" step has no counterpart here).
 *
 * This exists for the same reason find_media_device()/topology_records() exist
 * in the bash daemon: /dev/media0, /dev/v4l-subdev4 and /dev/video0 are
 * enumeration artifacts, so the daemon must not name them, and when libcamera
 * reports no cameras the operator needs to be told which half of the graph is
 * missing rather than "no cameras".
 */

struct MediaEntity {
	uint32_t id;
	std::string name;
	uint32_t function;
	std::string devnode;
};

std::string devnodeFor(uint32_t major, uint32_t minor)
{
	char path[128];
	snprintf(path, sizeof(path), "/sys/dev/char/%u:%u/uevent", major, minor);
	FILE *f = fopen(path, "r");
	if (!f)
		return {};
	char line[256];
	std::string name;
	while (fgets(line, sizeof(line), f)) {
		if (!strncmp(line, "DEVNAME=", 8)) {
			name = line + 8;
			while (!name.empty() && (name.back() == '\n' || name.back() == '\r'))
				name.pop_back();
			break;
		}
	}
	fclose(f);
	return name.empty() ? std::string() : "/dev/" + name;
}

struct MediaGraph {
	std::string device;
	std::vector<MediaEntity> entities;
	/* source entity id -> sink entity ids, data links only */
	std::multimap<uint32_t, uint32_t> links;

	const MediaEntity *findByPrefix(const char *prefix) const
	{
		size_t n = strlen(prefix);
		for (const auto &e : entities)
			if (!strncmp(e.name.c_str(), prefix, n))
				return &e;
		return nullptr;
	}
	const MediaEntity *byId(uint32_t id) const
	{
		for (const auto &e : entities)
			if (e.id == id)
				return &e;
		return nullptr;
	}
};

bool readTopology(int fd, MediaGraph &g)
{
	struct media_v2_topology topo = {};
	if (ioctl(fd, MEDIA_IOC_G_TOPOLOGY, &topo) < 0)
		return false;

	std::vector<media_v2_entity> ents(topo.num_entities);
	std::vector<media_v2_interface> ifaces(topo.num_interfaces);
	std::vector<media_v2_pad> pads(topo.num_pads);
	std::vector<media_v2_link> links(topo.num_links);

	topo.ptr_entities = ents.empty() ? 0 : reinterpret_cast<uint64_t>(ents.data());
	topo.ptr_interfaces = ifaces.empty() ? 0 : reinterpret_cast<uint64_t>(ifaces.data());
	topo.ptr_pads = pads.empty() ? 0 : reinterpret_cast<uint64_t>(pads.data());
	topo.ptr_links = links.empty() ? 0 : reinterpret_cast<uint64_t>(links.data());
	if (ioctl(fd, MEDIA_IOC_G_TOPOLOGY, &topo) < 0)
		return false;

	std::map<uint32_t, uint32_t> padToEntity;
	for (const auto &p : pads)
		padToEntity[p.id] = p.entity_id;

	std::map<uint32_t, const media_v2_interface *> ifaceById;
	for (const auto &i : ifaces)
		ifaceById[i.id] = &i;

	for (const auto &e : ents) {
		MediaEntity me;
		me.id = e.id;
		me.name = e.name;
		me.function = e.function;
		g.entities.push_back(me);
	}

	for (const auto &l : links) {
		uint32_t type = l.flags & MEDIA_LNK_FL_LINK_TYPE;
		if (type == MEDIA_LNK_FL_INTERFACE_LINK) {
			auto it = ifaceById.find(l.source_id);
			if (it == ifaceById.end())
				continue;
			for (auto &e : g.entities)
				if (e.id == l.sink_id)
					e.devnode = devnodeFor(it->second->devnode.major,
							       it->second->devnode.minor);
		} else if (type == MEDIA_LNK_FL_DATA_LINK) {
			auto s = padToEntity.find(l.source_id);
			auto d = padToEntity.find(l.sink_id);
			if (s != padToEntity.end() && d != padToEntity.end())
				g.links.insert({ s->second, d->second });
		}
	}
	return true;
}

/* Find the media device whose driver is intel-ipu7, by asking every /dev/media*
 * rather than assuming /dev/media0. MEDIA_DEVICE can pin it for debugging. */
bool findGraph(MediaGraph &g)
{
	std::vector<std::string> candidates;
	std::string pinned = envStr("MEDIA_DEVICE", "");
	if (!pinned.empty()) {
		candidates.push_back(pinned);
	} else {
		DIR *d = opendir("/dev");
		if (!d)
			return false;
		while (struct dirent *e = readdir(d))
			if (!strncmp(e->d_name, "media", 5))
				candidates.push_back(std::string("/dev/") + e->d_name);
		closedir(d);
	}

	for (const auto &path : candidates) {
		int fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		struct media_device_info info = {};
		if (ioctl(fd, MEDIA_IOC_DEVICE_INFO, &info) == 0 &&
		    !strcmp(info.driver, "intel-ipu7")) {
			g.device = path;
			bool ok = readTopology(fd, g);
			close(fd);
			return ok;
		}
		close(fd);
	}
	return false;
}

/* ------------------------------------------------------------ configuration */

enum class Engine { CamHal, SoftIsp };

/* Outside RuntimeDirectory= on purpose: systemd wipes that directory on every
 * service stop, and this flag has to survive Restart=always cycles to mean
 * "for the rest of the boot". /run itself dies with the boot, which is the
 * other half of the meaning. */
constexpr const char *kCamhalFallbackFlag =
	"/run/hp-elitebook-x-g2i-camera.camhal-fallback";

struct Config {
	std::string loop;
	unsigned int outW, outH;	 /* what the loopback advertises */
	unsigned int camW, camH;	 /* what libcamera is asked for: native mode */
	unsigned int fps;
	int idleStop;			 /* seconds without a consumer -> sensor off */
	int pollMs;			 /* consumer poll interval */
	int blackMs;			 /* black frame interval while idle */
	int frameTimeoutMs;		 /* no buffer for this long -> restart camera */
	int statusLogS;			 /* heartbeat status line interval, 0 = off */
	double aeTarget;
	int swsFlags;
	bool haveGamma, haveContrast, haveSaturation;
	double gamma, contrast, saturation;
	Engine engine;			 /* HPCAM_ENGINE, default camhal */
	bool engineForced;		 /* HPCAM_ENGINE was set explicitly */
	std::string camhalPrefix;	 /* the pinned runtime */
	std::string camhalSensor;	 /* icamerasrc device-name */
	int camhalStartMs;		 /* engine start -> first frame deadline */
	std::string aiqbOverride;	 /* local tuning drop-in, see the header */
	int nrStrength;			 /* HPCAM_NR_STRENGTH, forwarded to CamHAL */
	double denoise;			 /* HPCAM_DENOISE: vapostproc strength, 0 = no filter */
	std::string exposureRange;	 /* HPCAM_EXPOSURE_RANGE "min~max" us, empty = HAL AE */
	std::string gainRange;		 /* HPCAM_GAIN_RANGE "min~max", empty = HAL AE */
};

int swsFlagsFromName(const std::string &n)
{
	if (n == "bilinear")
		return SWS_BILINEAR;
	if (n == "bicubic")
		return SWS_BICUBIC;
	if (n == "area")
		return SWS_AREA;
	if (n == "lanczos")
		return SWS_LANCZOS;
	if (n == "point")
		return SWS_POINT;
	return SWS_FAST_BILINEAR;
}

/*
 * AE_TARGET, honestly translated.
 *
 * The bash daemon runs its own AE: it reads signalstats YAVG and drives the
 * sensor's exposure/analogue_gain/digital_gain until the mean luma reaches
 * AE_TARGET. libcamera's simple IPA owns exposure and gain here, and its AGC
 * (src/ipa/simple/algorithms/agc.cpp) targets a fixed Mean Sample Value of 2.5
 * over 5 histogram bins. Nothing in libcamera 0.7.2 exposes that target as a
 * control: the simple IPA's control map is exactly Gamma, Contrast and
 * Saturation (algorithms/adjust.cpp).
 *
 * So AE_TARGET here is NOT exposure control. It is a tone-curve trim that moves
 * the output mean in the same direction with the same units, by solving for the
 * gamma that maps the default result to the requested mean:
 *
 *   out = in^(1/g);  in^(1/2.2) = 105/255  =>  g = 2.2 * ln(105/255)/ln(T/255)
 *
 * GAMMA overrides it outright. Say so in the log, so nobody reads a gamma
 * change as an exposure change later.
 */
double gammaForAeTarget(double target)
{
	target = std::clamp(target, 8.0, 250.0);
	double g = 2.2 * std::log(105.0 / 255.0) / std::log(target / 255.0);
	return std::clamp(g, 0.1, 10.0);
}

/* "min~max" with both sides plain non-negative decimals — the only shape
 * icamerasrc's exposure-time-range/gain-range properties parse. The value goes
 * into the child's argv verbatim, so anything else is refused here, loudly,
 * rather than handed to a subprocess whose failure mode is the two-strikes
 * engine fallback. */
bool validRangeSpec(const std::string &s)
{
	size_t tilde = s.find('~');
	if (tilde == std::string::npos || tilde == 0 || tilde + 1 == s.size())
		return false;
	for (size_t i = 0; i < s.size(); i++) {
		if (i == tilde)
			continue;
		unsigned char ch = s[i];
		if (!isdigit(ch) && ch != '.')
			return false;
	}
	return true;
}

Config loadConfig()
{
	Config c;
	c.loop = envStr("LOOP", "/dev/video50");
	c.outW = (unsigned)envLong("OUT_W", 1920);
	c.outH = (unsigned)envLong("OUT_H", 1080);
	c.camW = (unsigned)envLong("CAM_W", 2888);
	c.camH = (unsigned)envLong("CAM_H", 1808);
	c.fps = (unsigned)envLong("FPS", 30);
	c.idleStop = (int)envLong("IDLE_STOP", 5);
	c.pollMs = (int)(envDouble("POLL", 1.0) * 1000);
	c.blackMs = (int)envLong("BLACK_MS", 200);
	c.frameTimeoutMs = (int)envLong("FRAME_TIMEOUT", 5) * 1000;
	c.statusLogS = (int)envLong("STATUS_LOG", 300);
	c.aeTarget = envDouble("AE_TARGET", 105);
	c.swsFlags = swsFlagsFromName(envStr("SWS_FLAGS", "fast_bilinear"));
	c.haveGamma = envHas("GAMMA");
	c.haveContrast = envHas("CONTRAST");
	c.haveSaturation = envHas("SATURATION");
	c.gamma = envDouble("GAMMA", 2.2);
	c.contrast = envDouble("CONTRAST", 1.0);
	c.saturation = envDouble("SATURATION", 1.0);

	std::string eng = envStr("HPCAM_ENGINE", "camhal");
	if (eng == "softisp") {
		c.engine = Engine::SoftIsp;
	} else {
		if (eng != "camhal")
			logf("HPCAM_ENGINE=%s not understood — using camhal",
			     eng.c_str());
		c.engine = Engine::CamHal;
	}
	c.engineForced = envHas("HPCAM_ENGINE");
	c.camhalPrefix = envStr("CAMHAL_PREFIX", "/usr/lib/hp-elitebook-x-g2i-camhal");
	c.camhalSensor = envStr("CAMHAL_SENSOR", "ov05c10-uf");
	c.camhalStartMs = (int)envLong("CAMHAL_START_TIMEOUT", 10) * 1000;
	c.aiqbOverride = envStr("CAMHAL_AIQB_OVERRIDE",
				"/etc/hp-elitebook-x-g2i/OV05C10_CJFPE50_PTL.aiqb");
	/* Noise-reduction strength for the runtime's patched HAL. Same scale as
	 * the HAL's own presets: LEVEL3 = -60, LEVEL4 = -120, default LEVEL2 = 0.
	 * -60 measured ~28% less within-frame dark-scene noise, -120 ~45%; the
	 * shipped default stays at the conservative -60 until -120 has passed a
	 * daylight check. 0 is the HAL's untouched behaviour. */
	c.nrStrength = (int)envLong("HPCAM_NR_STRENGTH", -60);
	if (c.nrStrength < -128 || c.nrStrength > 127) {
		logf("HPCAM_NR_STRENGTH=%d out of the HAL's signed-char range — "
		     "using -60", c.nrStrength);
		c.nrStrength = -60;
	}

	/* GPU temporal denoise (Intel VEBOX, via the system vapostproc). The
	 * range is vapostproc's own: float 0-64, its default 0. 0 removes the
	 * filter element entirely, which restores the 2.0.1 pipeline and reader
	 * byte-identically; see the header. */
	c.denoise = envDouble("HPCAM_DENOISE", 8.0);
	if (std::isnan(c.denoise)) {
		logf("HPCAM_DENOISE is not a number — using 8");
		c.denoise = 8.0;
	} else if (c.denoise < 0.0 || c.denoise > 64.0) {
		double clamped = std::clamp(c.denoise, 0.0, 64.0);
		logf("HPCAM_DENOISE=%g outside vapostproc's 0-64 range — "
		     "clamping to %g", c.denoise, clamped);
		c.denoise = clamped;
	}

	/* Optional AE clamps, handed to icamerasrc verbatim. Empty means the
	 * HAL's own AE limits — which on this machine pin exposure at 33ms and
	 * ride 12.5-15.5x analog gain; see the conf file. */
	c.exposureRange = envStr("HPCAM_EXPOSURE_RANGE", "");
	if (!c.exposureRange.empty() && !validRangeSpec(c.exposureRange)) {
		logf("HPCAM_EXPOSURE_RANGE=%s is not min~max — ignoring",
		     c.exposureRange.c_str());
		c.exposureRange.clear();
	}
	c.gainRange = envStr("HPCAM_GAIN_RANGE", "");
	if (!c.gainRange.empty() && !validRangeSpec(c.gainRange)) {
		logf("HPCAM_GAIN_RANGE=%s is not min~max — ignoring",
		     c.gainRange.c_str());
		c.gainRange.clear();
	}

	if (c.outW % 2 || c.outH % 2) {
		logf("OUT_W/OUT_H must be even (NV12); got %ux%u", c.outW, c.outH);
		exit(1);
	}
	if (c.pollMs < 100)
		c.pollMs = 100;
	return c;
}

/* ------------------------------------------------------------------ daemon */

class Daemon
{
public:
	explicit Daemon(const Config &cfg) : cfg_(cfg) {}
	int run();

private:
	enum class State { Idle, Active };

	bool openLoopback();
	void writeFrame(const uint8_t *data, size_t len);
	void makeBlackFrame();

	bool cameraInit();
	bool cameraStart();
	void cameraStop(const char *why);
	void requestComplete(Request *request);

	/* engine dispatch: A = camhal (gst subprocess), B = softisp (libcamera) */
	bool engineStart();
	void engineStop(const char *why);
	const char *engineName() const;
	bool softispStart();
	bool camhalStart();
	void camhalStop(const char *why);
	void camhalReader();
	size_t camhalChunkSize() const;
	void camhalAccountFailure(const char *what);
	std::string camhalCfgPath();

	unsigned int countConsumers();

	Config cfg_;

	int loopFd_ = -1;
	dev_t loopRdev_ = 0;
	size_t frameSize_ = 0;
	std::vector<uint8_t> black_;
	std::mutex outMutex_;
	pid_t self_ = 0;

	std::unique_ptr<CameraManager> cm_;
	std::shared_ptr<Camera> camera_;
	Stream *stream_ = nullptr;
	std::unique_ptr<FrameBufferAllocator> allocator_;
	std::vector<std::unique_ptr<Request>> requests_;
	std::map<int, std::pair<void *, size_t>> maps_;
	unsigned int srcW_ = 0, srcH_ = 0, srcStride_ = 0;
	unsigned int cropX_ = 0, cropY_ = 0, cropW_ = 0, cropH_ = 0;
	SwsContext *sws_ = nullptr;
	std::vector<uint8_t> nv12_;

	State state_ = State::Idle;
	std::atomic<uint64_t> lastCameraFrame_{ 0 };
	std::atomic<uint64_t> cameraFrames_{ 0 };
	std::atomic<bool> writeFailed_{ false };
	std::atomic<bool> fatal_{ false };

	/* engine A state */
	Engine engine_ = Engine::CamHal;
	bool camhalFellBack_ = false;
	unsigned int camhalFailures_ = 0;	/* consecutive; 2 => fallback */
	pid_t gstPid_ = -1;
	int gstFd_ = -1;			/* read end of the frame pipe */
	std::thread gstThread_;
	std::atomic<bool> gstEof_{ false };
	std::atomic<uint64_t> sessionFrames_{ 0 };
	/* Set before Camera::stop(). Requests that complete during the stop are
	 * dropped rather than re-queued: libcamera reports FrameSuccess for
	 * buffers already in flight, and queueRequest() on a camera in the
	 * Stopping state logs an error for every one of them. */
	std::atomic<bool> stopping_{ false };
	/* Guards the stopping_ / queueRequest() pair only. Never held across
	 * Camera::stop(), which waits for the callback that would be holding
	 * it. */
	std::mutex requeueMutex_;

	/* observability */
	std::string rundir_;
	std::string reason_ = "startup";
	uint64_t startedAt_ = 0;
	uint64_t stateSince_ = 0;
	unsigned int consumers_ = 0;
	unsigned int sensorStarts_ = 0;
	unsigned int sensorFailures_ = 0;
	unsigned int sensorW_ = 0, sensorH_ = 0;
	uint64_t fpsWindowStart_ = 0;
	uint64_t fpsWindowFrames_ = 0;
	double fps_ = 0;
	std::string statusLine() const;
	void publishStatus();
};

/*
 * One greppable line describing everything about the current state, including
 * why it is in it. The bash daemon's transition lines ("sensor idle — feeding
 * black (LED off)") are what made cold-boot verification a one-command job, so
 * this keeps that and adds the numbers: nothing is logged per frame.
 */
std::string Daemon::statusLine() const
{
	char buf[512];
	uint64_t now = monoMs();
	std::string sensor = state_ == State::Active
				     ? std::to_string(sensorW_) + "x" +
					       std::to_string(sensorH_)
				     : std::string("off");
	snprintf(buf, sizeof(buf),
		 "status: state=%s engine=%s reason=\"%s\" for=%llus consumers=%u led=%s "
		 "loop=%s out=%ux%u sensor=%s fps=%.1f frames=%llu "
		 "sensor_starts=%u sensor_failures=%u uptime=%llus pid=%d",
		 state_ == State::Active ? "active" : "idle", engineName(), reason_.c_str(),
		 (unsigned long long)((now - stateSince_) / 1000), consumers_,
		 state_ == State::Active ? "on" : "off", cfg_.loop.c_str(),
		 cfg_.outW, cfg_.outH, sensor.c_str(), fps_, (unsigned long long)cameraFrames_.load(), sensorStarts_,
		 sensorFailures_, (unsigned long long)((now - startedAt_) / 1000),
		 (int)self_);
	return std::string(buf);
}

/*
 * Same information as a file, so a check does not have to trawl the journal.
 * Written by rename(2) so a reader never sees a half-written file. Lives in the
 * unit's RuntimeDirectory (0700, root-owned) for the same reason the bash
 * daemon puts its FIFO there.
 */
void Daemon::publishStatus()
{
	if (rundir_.empty())
		return;
	std::string tmp = rundir_ + "/status.tmp";
	std::string dst = rundir_ + "/status";
	FILE *f = fopen(tmp.c_str(), "w");
	if (!f)
		return;
	uint64_t now = monoMs();
	fprintf(f, "state=%s\n", state_ == State::Active ? "active" : "idle");
	fprintf(f, "engine=%s\n", engineName());
	fprintf(f, "engine_fallback=%s\n", camhalFellBack_ ? "yes" : "no");
	fprintf(f, "camhal_failures=%u\n", camhalFailures_);
	fprintf(f, "reason=%s\n", reason_.c_str());
	fprintf(f, "state_seconds=%llu\n",
		(unsigned long long)((now - stateSince_) / 1000));
	fprintf(f, "consumers=%u\n", consumers_);
	fprintf(f, "led=%s\n", state_ == State::Active ? "on" : "off");
	fprintf(f, "loop=%s\n", cfg_.loop.c_str());
	fprintf(f, "out=%ux%u\n", cfg_.outW, cfg_.outH);
	fprintf(f, "nominal_fps=%u\n", cfg_.fps);
	if (state_ == State::Active)
		fprintf(f, "sensor=%ux%u\n", sensorW_, sensorH_);
	else
		fprintf(f, "sensor=off\n");
	fprintf(f, "fps=%.1f\n", fps_);
	fprintf(f, "frames=%llu\n", (unsigned long long)cameraFrames_.load());
	fprintf(f, "sensor_starts=%u\n", sensorStarts_);
	fprintf(f, "sensor_failures=%u\n", sensorFailures_);
	fprintf(f, "idle_stop=%d\n", cfg_.idleStop);
	fprintf(f, "uptime_seconds=%llu\n",
		(unsigned long long)((now - startedAt_) / 1000));
	fprintf(f, "pid=%d\n", (int)self_);
	fclose(f);
	if (rename(tmp.c_str(), dst.c_str()) < 0)
		unlink(tmp.c_str());
}

/* One whole frame, one write(2), one mutex. See the header. */
void Daemon::writeFrame(const uint8_t *data, size_t len)
{
	std::lock_guard<std::mutex> lock(outMutex_);
	while (len) {
		ssize_t n = ::write(loopFd_, data, len);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			logf("write to %s failed: %s", cfg_.loop.c_str(), strerror(errno));
			writeFailed_ = true;
			return;
		}
		data += n;
		len -= n;
	}
}

/* Y=16, UV=128. An all-zero NV12 frame renders bright green, which looks like a
 * fault; the bash daemon learned this too (make_black_frame). */
void Daemon::makeBlackFrame()
{
	size_t ysz = size_t(cfg_.outW) * cfg_.outH;
	black_.assign(ysz, 16);
	black_.resize(ysz + ysz / 2, 128);
	frameSize_ = black_.size();
}

bool Daemon::openLoopback()
{
	/* The unit's ExecStartPre runs modprobe, but a kernel upgrade can leave
	 * the node appearing a moment later. Wait briefly rather than dying and
	 * being restarted 5 s later by systemd. */
	for (int i = 0; i < 50; i++) {
		loopFd_ = ::open(cfg_.loop.c_str(), O_RDWR | O_CLOEXEC);
		if (loopFd_ >= 0)
			break;
		usleep(200000);
	}
	if (loopFd_ < 0) {
		logf("open %s: %s", cfg_.loop.c_str(), strerror(errno));
		return false;
	}

	struct stat st;
	if (fstat(loopFd_, &st) < 0 || !S_ISCHR(st.st_mode)) {
		logf("%s is not a character device", cfg_.loop.c_str());
		return false;
	}
	loopRdev_ = st.st_rdev;

	struct v4l2_format fmt = {};
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fmt.fmt.pix.width = cfg_.outW;
	fmt.fmt.pix.height = cfg_.outH;
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_NV12;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;
	fmt.fmt.pix.bytesperline = cfg_.outW;
	fmt.fmt.pix.sizeimage = cfg_.outW * cfg_.outH * 3 / 2;
	fmt.fmt.pix.colorspace = V4L2_COLORSPACE_SMPTE170M;
	if (::ioctl(loopFd_, VIDIOC_S_FMT, &fmt) < 0) {
		logf("VIDIOC_S_FMT on %s: %s", cfg_.loop.c_str(), strerror(errno));
		return false;
	}
	if (fmt.fmt.pix.width != cfg_.outW || fmt.fmt.pix.height != cfg_.outH ||
	    fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_NV12) {
		logf("%s refused NV12 %ux%u", cfg_.loop.c_str(), cfg_.outW, cfg_.outH);
		return false;
	}

	struct v4l2_streamparm parm = {};
	parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	parm.parm.output.timeperframe.numerator = 1;
	parm.parm.output.timeperframe.denominator = cfg_.fps;
	if (::ioctl(loopFd_, VIDIOC_S_PARM, &parm) < 0)
		logf("VIDIOC_S_PARM (non-fatal): %s", strerror(errno));

	return true;
}

/*
 * Consumers of the loopback other than ourselves. Same definition as the bash
 * daemon's consumers(), which shells out to fuser(1) once a second; this walks
 * /proc directly and compares st_rdev, so a symlinked path such as
 * /dev/v4l/by-id/... counts as the same device. A consumer that dies without
 * closing cleanly stops being counted the moment the kernel reaps its fds,
 * which is the behaviour the bash daemon relies on too.
 */
unsigned int Daemon::countConsumers()
{
	unsigned int n = 0;
	DIR *proc = opendir("/proc");
	if (!proc)
		return 0;

	while (struct dirent *pe = readdir(proc)) {
		if (pe->d_name[0] < '0' || pe->d_name[0] > '9')
			continue;
		pid_t pid = atoi(pe->d_name);
		if (pid == self_)
			continue;

		char fdpath[64];
		snprintf(fdpath, sizeof(fdpath), "/proc/%d/fd", pid);
		DIR *fds = opendir(fdpath);
		if (!fds)
			continue;

		bool holds = false;
		while (struct dirent *fe = readdir(fds)) {
			if (fe->d_name[0] == '.')
				continue;
			char full[320];
			snprintf(full, sizeof(full), "%s/%s", fdpath, fe->d_name);
			struct stat st;
			if (stat(full, &st) == 0 && S_ISCHR(st.st_mode) &&
			    st.st_rdev == loopRdev_) {
				holds = true;
				break;
			}
		}
		closedir(fds);
		if (holds)
			n++;
	}
	closedir(proc);
	return n;
}

/* ------------------------------------------------------------------ camera */

std::atomic<bool> g_stop{ false };
std::atomic<bool> g_status{ false };

void onSignal(int)
{
	g_stop = true;
}

/* SIGUSR1 prints the status line into the journal on demand. */
void onStatusSignal(int)
{
	g_status = true;
}

bool Daemon::cameraInit()
{
	/* The tuning file ov05c10.yaml is installed in the system data dir. When
	 * this runs against a libcamera in a non-system prefix, that dir is not
	 * searched, so add it. Additive: the prefix's own dir is still the
	 * fallback (IPAProxy::ipaConfigurationFile). */
	if (!envHas("LIBCAMERA_IPA_CONFIG_PATH"))
		setenv("LIBCAMERA_IPA_CONFIG_PATH", "/usr/share/libcamera/ipa", 1);

	cm_ = std::make_unique<CameraManager>();
	if (cm_->start()) {
		logf("CameraManager::start failed");
		return false;
	}

	/* Select by sensor model, not by index. cameras()[0] is an enumeration
	 * artifact in exactly the way /dev/video0 is. */
	for (const auto &cam : cm_->cameras()) {
		const auto &props = cam->properties();
		auto model = props.get(properties::Model);
		if (model && std::string(*model).find("ov05c10") != std::string::npos) {
			camera_ = cam;
			break;
		}
	}
	if (!camera_) {
		logf("no ov05c10 camera among %zu libcamera camera(s)",
		     cm_->cameras().size());
		for (const auto &cam : cm_->cameras()) {
			auto model = cam->properties().get(properties::Model);
			logf("  seen: id=%s model=%s", cam->id().c_str(),
			     model ? std::string(*model).c_str() : "?");
		}
		return false;
	}

	auto model = camera_->properties().get(properties::Model);
	logf("libcamera camera: id=%s model=%s", camera_->id().c_str(),
	     model ? std::string(*model).c_str() : "?");
	return true;
}

bool Daemon::cameraStart()
{
	if (camera_->acquire()) {
		logf("camera acquire failed — something else holds the sensor");
		return false;
	}

	auto config = camera_->generateConfiguration({ StreamRole::Viewfinder });
	if (!config || config->empty()) {
		logf("generateConfiguration failed");
		camera_->release();
		return false;
	}

	StreamConfiguration &cfg = config->at(0);
	cfg.pixelFormat = formats::XRGB8888;
	cfg.size = Size(cfg_.camW, cfg_.camH);
	cfg.bufferCount = 4;

	CameraConfiguration::Status st = config->validate();
	if (st == CameraConfiguration::Invalid) {
		logf("configuration invalid");
		camera_->release();
		return false;
	}
	if (cfg.pixelFormat != formats::XRGB8888) {
		logf("pixel format adjusted to %s; only XRGB8888 is handled",
		     cfg.pixelFormat.toString().c_str());
		camera_->release();
		return false;
	}
	/*
	 * A small shrink is expected and fine: the debayer keeps a border of one
	 * Bayer pattern on each side, so the largest output of the 2888x1808
	 * sensor mode is (2888 - 2*2) & ~1 = 2884 wide
	 * (DebayerCpu::sizes()/DebayerEGL::sizes()). Anything smaller than that
	 * means validate() picked a different sensor mode -- for 1920x1080 it
	 * picks 2800x1576, which never delivers a buffer and wedges the ISYS
	 * node. Refuse rather than stream into it.
	 */
	if (cfg.size.width + 8 < cfg_.camW || cfg.size.height + 8 < cfg_.camH) {
		logf("size adjusted to %s, too far below the requested %ux%u — "
		     "refusing: that means a non-native sensor mode, which "
		     "wedges the ISYS node",
		     cfg.size.toString().c_str(), cfg_.camW, cfg_.camH);
		camera_->release();
		return false;
	}
	if (cfg.size != Size(cfg_.camW, cfg_.camH))
		logf("stream size adjusted %ux%u -> %s (debayer border)",
		     cfg_.camW, cfg_.camH, cfg.size.toString().c_str());

	if (camera_->configure(config.get())) {
		logf("configure failed");
		camera_->release();
		return false;
	}

	srcW_ = cfg.size.width;
	srcH_ = cfg.size.height;
	srcStride_ = cfg.stride;
	stream_ = cfg.stream();

	/*
	 * Centre-crop the sensor frame to the output aspect ratio before
	 * scaling, which is what DebayerEGL would do on the GPU if the output
	 * size could be requested directly ("keep the aspect ratio and prefer
	 * cropping over black bars"). The old ffmpeg chain instead stretched
	 * 2888x1808 into 1920x1080, so it is geometrically wrong today; this is
	 * a deliberate difference, not a regression.
	 */
	double srcAspect = double(srcW_) / srcH_;
	double dstAspect = double(cfg_.outW) / cfg_.outH;
	if (dstAspect > srcAspect) {
		cropW_ = srcW_;
		cropH_ = (unsigned)(srcW_ / dstAspect) & ~1u;
		if (cropH_ > srcH_)
			cropH_ = srcH_ & ~1u;
	} else {
		cropH_ = srcH_;
		cropW_ = (unsigned)(srcH_ * dstAspect) & ~1u;
		if (cropW_ > srcW_)
			cropW_ = srcW_ & ~1u;
	}
	cropX_ = ((srcW_ - cropW_) / 2) & ~1u;
	cropY_ = ((srcH_ - cropH_) / 2) & ~1u;

	sws_ = sws_getContext(cropW_, cropH_, AV_PIX_FMT_BGR0,
			      cfg_.outW, cfg_.outH, AV_PIX_FMT_NV12,
			      cfg_.swsFlags, nullptr, nullptr, nullptr);
	if (!sws_) {
		logf("sws_getContext failed");
		camera_->release();
		return false;
	}
	/* BT.601 limited range out, matching what format=nv12 produced before. */
	const int *tbl = sws_getCoefficients(SWS_CS_ITU601);
	sws_setColorspaceDetails(sws_, tbl, 0, tbl, 0, 0, 1 << 16, 1 << 16);

	nv12_.resize(frameSize_);

	allocator_ = std::make_unique<FrameBufferAllocator>(camera_);
	if (allocator_->allocate(stream_) < 0) {
		logf("buffer allocation failed");
		sws_freeContext(sws_);
		sws_ = nullptr;
		camera_->release();
		return false;
	}

	bool ok = true;
	for (const auto &buffer : allocator_->buffers(stream_)) {
		const FrameBuffer::Plane &plane = buffer->planes()[0];
		int fd = plane.fd.get();
		if (!maps_.count(fd)) {
			size_t len = plane.offset + plane.length;
			void *p = mmap(nullptr, len, PROT_READ, MAP_SHARED, fd, 0);
			if (p == MAP_FAILED) {
				logf("mmap: %s", strerror(errno));
				ok = false;
				break;
			}
			maps_[fd] = { p, len };
		}
		std::unique_ptr<Request> request = camera_->createRequest();
		if (!request || request->addBuffer(stream_, buffer.get()) < 0) {
			logf("request setup failed");
			ok = false;
			break;
		}
		requests_.push_back(std::move(request));
	}

	double gamma = cfg_.haveGamma ? cfg_.gamma : gammaForAeTarget(cfg_.aeTarget);
	if (ok) {
		camera_->requestCompleted.connect(this, &Daemon::requestComplete);

		ControlList ctrls(camera_->controls());
		ctrls.set(controls::Gamma, (float)gamma);
		if (cfg_.haveContrast)
			ctrls.set(controls::Contrast, (float)cfg_.contrast);
		if (cfg_.haveSaturation)
			ctrls.set(controls::Saturation, (float)cfg_.saturation);

		if (camera_->start(&ctrls)) {
			logf("camera start failed");
			camera_->requestCompleted.disconnect(this, &Daemon::requestComplete);
			ok = false;
		}
	}

	if (!ok) {
		requests_.clear();
		for (auto &[fd, m] : maps_)
			munmap(m.first, m.second);
		maps_.clear();
		allocator_->free(stream_);
		allocator_.reset();
		sws_freeContext(sws_);
		sws_ = nullptr;
		camera_->release();
		return false;
	}

	logf("consumer present — sensor streaming %ux%u (LED on), "
	     "crop %ux%u+%u+%u -> %ux%u, gamma %.2f",
	     srcW_, srcH_, cropW_, cropH_, cropX_, cropY_,
	     cfg_.outW, cfg_.outH, gamma);

	lastCameraFrame_ = monoMs();
	for (auto &request : requests_)
		camera_->queueRequest(request.get());
	return true;
}

/*
 * Frame-boundary safe by construction. Camera::stop() completes and cancels
 * every in-flight request before it returns, and requestComplete() only ever
 * writes whole frames, so once this returns the loopback has received an exact
 * number of complete frames and the black feeder can take over immediately.
 */
void Daemon::cameraStop(const char *why)
{
	{
		std::lock_guard<std::mutex> lock(requeueMutex_);
		stopping_ = true;
	}
	camera_->stop();
	camera_->requestCompleted.disconnect(this, &Daemon::requestComplete);

	requests_.clear();
	for (auto &[fd, m] : maps_)
		munmap(m.first, m.second);
	maps_.clear();
	if (allocator_) {
		allocator_->free(stream_);
		allocator_.reset();
	}
	if (sws_) {
		sws_freeContext(sws_);
		sws_ = nullptr;
	}
	/* release() is what drops the media device lock, so another program (or
	 * the bash daemon, on rollback) can take the sensor while we idle. */
	camera_->release();
	stopping_ = false;
	logf("%s — sensor stopped and released (LED off), feeding black", why);
}

void Daemon::requestComplete(Request *request)
{
	if (request->status() == Request::RequestCancelled || stopping_ || g_stop)
		return;

	FrameBuffer *buffer = request->buffers().begin()->second;
	if (buffer->metadata().status == FrameMetadata::FrameSuccess) {
		auto it = maps_.find(buffer->planes()[0].fd.get());
		if (it != maps_.end()) {
			const uint8_t *src = static_cast<uint8_t *>(it->second.first) +
					     buffer->planes()[0].offset +
					     size_t(cropY_) * srcStride_ + size_t(cropX_) * 4;
			const uint8_t *srcData[4] = { src, nullptr, nullptr, nullptr };
			int srcLines[4] = { (int)srcStride_, 0, 0, 0 };
			uint8_t *dstData[4] = { nv12_.data(),
						nv12_.data() + size_t(cfg_.outW) * cfg_.outH,
						nullptr, nullptr };
			int dstLines[4] = { (int)cfg_.outW, (int)cfg_.outW, 0, 0 };
			sws_scale(sws_, srcData, srcLines, 0, cropH_, dstData, dstLines);
			writeFrame(nv12_.data(), nv12_.size());
			lastCameraFrame_ = monoMs();
			cameraFrames_++;
		}
	}

	/* Re-check under the lock: without it a callback that passed the check
	 * above can still reach queueRequest() after Camera::stop() has moved
	 * the camera to Stopping, which libcamera logs as an error. */
	std::lock_guard<std::mutex> lock(requeueMutex_);
	if (stopping_ || g_stop)
		return;
	request->reuse(Request::ReuseBuffers);
	camera_->queueRequest(request);
}

/* --------------------------------------------------------- engine dispatch */

const char *Daemon::engineName() const
{
	if (engine_ == Engine::CamHal)
		return "camhal";
	return camhalFellBack_ ? "softisp-fallback" : "softisp";
}

bool Daemon::engineStart()
{
	return engine_ == Engine::CamHal ? camhalStart() : softispStart();
}

void Daemon::engineStop(const char *why)
{
	if (engine_ == Engine::CamHal)
		camhalStop(why);
	else
		cameraStop(why);
}

/* Engine B start. libcamera is initialised here, not at daemon startup,
 * because in camhal mode it must never run at all (see the header). */
bool Daemon::softispStart()
{
	if (!cm_ && !cameraInit()) {
		logf("libcamera init failed at softisp start — exiting so systemd "
		     "restarts us (the fallback flag, if set, keeps us on softisp)");
		fatal_ = true;
		return false;
	}
	return cameraStart();
}

/* Called after every failed camhal attempt. Two strikes and softisp owns the
 * rest of the boot. Not when HPCAM_ENGINE=camhal was forced: that is the
 * debugging mode, and silently switching engines under a debugger is worse
 * than failing visibly forever. */
void Daemon::camhalAccountFailure(const char *what)
{
	camhalFailures_++;
	logf("camhal engine failure %u (fallback at 2): %s", camhalFailures_, what);
	if (camhalFailures_ < 2)
		return;
	if (cfg_.engineForced) {
		logf("HPCAM_ENGINE=camhal is forced — not falling back, will keep "
		     "retrying with backoff");
		return;
	}
	engine_ = Engine::SoftIsp;
	camhalFellBack_ = true;
	FILE *f = fopen(kCamhalFallbackFlag, "w");
	if (f) {
		fprintf(f, "%s\n", what);
		fclose(f);
	}
	logf("ENGINE FALLBACK: CamHAL failed twice in a row — using the SoftISP "
	     "engine for the rest of this boot. Re-arm: rm %s and restart the "
	     "service, or set HPCAM_ENGINE=camhal.", kCamhalFallbackFlag);
}

/* ------------------------------------------------- engine A: CamHAL via gst
 *
 * icamerasrc hands fdsink buffers of the HAL's frame size, not GStreamer's:
 * gstcamerasrcbufferpool.cpp sizes its pool from get_frame_size(), and for
 * NV12 that is stride ALIGN64(W), the W*H*3/2 payload laid out at that
 * stride, plus a spare tail of max(stride*3/2, 1024) bytes that PSYS kernels
 * are allowed to touch (CameraUtils::getFrameSize(), needExtraSize defaults
 * true, in the PINNED HAL this math must track). Verified against the HAL's
 * own log: 3113280 bytes per 1920x1080 frame vs GStreamer's 3110400. The
 * reader consumes exactly one chunk per frame and forwards only the payload,
 * so writeFrame() still writes whole, exact-sizeimage frames.
 */
size_t Daemon::camhalChunkSize() const
{
	/* With the denoise filter in the chain (HPCAM_DENOISE > 0) fdsink is
	 * fed by vapostproc, not icamerasrc, and vapostproc's buffers are the
	 * negotiated caps exactly: packed NV12, W*H*3/2, no HAL stride and no
	 * spare tail. The padded math below describes icamerasrc's buffers
	 * only, so it applies only to the filterless pipeline. */
	if (cfg_.denoise > 0)
		return frameSize_;
	size_t stride = (size_t(cfg_.outW) + 63) & ~size_t(63);
	size_t payload = stride * cfg_.outH * 3 / 2;
	size_t extra = std::max(stride * 3 / 2, size_t(1024));
	return payload + extra;
}

void Daemon::camhalReader()
{
	const size_t chunk = camhalChunkSize();
	/* Packed frames when the denoise filter feeds fdsink (chunk is exactly
	 * frameSize_ and the fast path below forwards it whole); the HAL's
	 * 64-aligned stride otherwise. Either way one chunk is one frame, and a
	 * partial chunk at EOF is discarded, never written. */
	const size_t stride = cfg_.denoise > 0
				      ? size_t(cfg_.outW)
				      : (size_t(cfg_.outW) + 63) & ~size_t(63);
	std::vector<uint8_t> buf(chunk);
	std::vector<uint8_t> packed;
	if (stride != cfg_.outW)
		packed.resize(frameSize_);
	size_t have = 0;

	for (;;) {
		ssize_t n = read(gstFd_, buf.data() + have, chunk - have);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (n == 0)
			break;
		have += size_t(n);
		if (have < chunk)
			continue;
		have = 0;

		if (stride == cfg_.outW) {
			/* 1920 is 64-aligned, so the default config lands here
			 * and the payload is a contiguous prefix of the chunk. */
			writeFrame(buf.data(), frameSize_);
		} else {
			/* De-stride row by row; Y and UV rows both carry outW
			 * useful bytes at the same stride. Only reachable with
			 * a non-64-aligned OUT_W override. */
			const unsigned int rows = cfg_.outH * 3 / 2;
			for (unsigned int r = 0; r < rows; r++)
				memcpy(packed.data() + size_t(r) * cfg_.outW,
				       buf.data() + size_t(r) * stride, cfg_.outW);
			writeFrame(packed.data(), frameSize_);
		}
		lastCameraFrame_ = monoMs();
		cameraFrames_++;
		sessionFrames_++;
	}
	/* EOF or error: the subprocess is gone (or its fd 3 is). A partial
	 * chunk is discarded here, never written, so the loopback cannot see a
	 * torn frame in this direction either. */
	gstEof_ = true;
}

/* The CAMERA_CFG_PATH the subprocess gets. The stock tuning lives in the
 * runtime prefix; a local aiqb drop-in promotes it to an overlay copy in the
 * RuntimeDirectory (see the header). Always ends in the trailing slash the
 * HAL requires. Re-evaluated on every engine start on purpose. */
std::string Daemon::camhalCfgPath()
{
	std::string base = cfg_.camhalPrefix + "/etc/camera/ipu75xa";
	struct stat st;
	if (stat(cfg_.aiqbOverride.c_str(), &st) != 0 || !S_ISREG(st.st_mode))
		return base + "/";
	if (rundir_.empty()) {
		logf("aiqb override %s present but there is no runtime directory "
		     "to stage the overlay in — using the stock tuning",
		     cfg_.aiqbOverride.c_str());
		return base + "/";
	}
	std::string overlay = rundir_ + "/camera-cfg";
	removeTree(overlay);
	if (!copyTree(base, overlay) ||
	    !copyFile(cfg_.aiqbOverride, overlay + "/OV05C10_CJFPE50_PTL.aiqb")) {
		logf("aiqb override %s present but staging the overlay in %s "
		     "failed (%s) — using the stock tuning",
		     cfg_.aiqbOverride.c_str(), overlay.c_str(), strerror(errno));
		removeTree(overlay);
		return base + "/";
	}
	logf("AIQB OVERRIDE: %s (%lld bytes) replaces the stock "
	     "OV05C10_CJFPE50_PTL.aiqb for this session, staged in %s",
	     cfg_.aiqbOverride.c_str(), (long long)st.st_size, overlay.c_str());
	return overlay + "/";
}

bool Daemon::camhalStart()
{
	char caps[96];
	snprintf(caps, sizeof(caps), "video/x-raw,format=NV12,width=%u,height=%u",
		 cfg_.outW, cfg_.outH);

	/* The pipeline, one token per argv slot. HPCAM_DENOISE > 0 adds the
	 * VEBOX temporal denoise stage, and its trailing capsfilter pins the
	 * output to packed NV12 at the same size — the contract behind the
	 * conditional camhalChunkSize(). The AE range knobs were validated in
	 * loadConfig and pass through verbatim. With everything at its default
	 * except HPCAM_DENOISE=0 this argv is byte-identical to 2.0.1's. */
	std::vector<std::string> args = { "gst-launch-1.0", "-q",
					  "icamerasrc",
					  "device-name=" + cfg_.camhalSensor };
	if (!cfg_.exposureRange.empty()) {
		args.push_back("exposure-time-range=" + cfg_.exposureRange);
		logf("AE knob: exposure-time-range=%s us applied to icamerasrc",
		     cfg_.exposureRange.c_str());
	}
	if (!cfg_.gainRange.empty()) {
		args.push_back("gain-range=" + cfg_.gainRange);
		logf("AE knob: gain-range=%s applied to icamerasrc",
		     cfg_.gainRange.c_str());
	}
	args.push_back("!");
	args.push_back(caps);
	if (cfg_.denoise > 0) {
		char dn[32];
		snprintf(dn, sizeof(dn), "denoise=%g", cfg_.denoise);
		args.insert(args.end(), { "!", "vapostproc", dn, "!", caps });
	}
	args.insert(args.end(), { "!", "fdsink", "fd=3" });

	/* The same tokens as one string, for the start log and the journal. */
	std::string pipeline;
	for (size_t i = 2; i < args.size(); i++) {
		if (i > 2)
			pipeline += " ";
		pipeline += args[i];
	}

	int pfd[2];
	if (pipe2(pfd, O_CLOEXEC) < 0) {
		logf("pipe2: %s", strerror(errno));
		return false;
	}
	/* Fewer wakeups for 3 MB frames. Best effort; the 64k default works. */
	(void)fcntl(pfd[0], F_SETPIPE_SZ, 1 << 20);

	/* The environment that makes gst-launch load the pinned runtime rather
	 * than anything system-wide. CAMERA_CFG_PATH keeps its trailing slash:
	 * the HAL appends "gcss/" to it verbatim. GST_REGISTRY keeps root's
	 * plugin cache out of /root/.cache. Built before fork so the child does
	 * nothing but exec. */
	std::string cfgPath = camhalCfgPath();
	std::vector<std::string> envs;
	for (char **e = environ; e && *e; e++) {
		if (!strncmp(*e, "LD_LIBRARY_PATH=", 16) ||
		    !strncmp(*e, "GST_PLUGIN_PATH=", 16) ||
		    !strncmp(*e, "CAMERA_CFG_PATH=", 16) ||
		    !strncmp(*e, "GST_REGISTRY=", 13) ||
		    !strncmp(*e, "HPCAM_NR_STRENGTH=", 18))
			continue;
		envs.push_back(*e);
	}
	/* GST_PLUGIN_PATH is additive — the system plugin dirs are still
	 * scanned — which is how the denoise stage's vapostproc (system
	 * gst-plugin-va) loads next to the prefix's icamerasrc in one pipeline.
	 * gst-va opens /dev/dri/renderD* directly (we run as root) and needs no
	 * LIBVA_* variables, and the prefix ships no GStreamer core libs for
	 * LD_LIBRARY_PATH to shadow. Both facts verified with gst-inspect-1.0
	 * under exactly this environment, 2026-08-31. */
	envs.push_back("LD_LIBRARY_PATH=" + cfg_.camhalPrefix + "/lib");
	envs.push_back("GST_PLUGIN_PATH=" + cfg_.camhalPrefix + "/lib/gstreamer-1.0");
	envs.push_back("CAMERA_CFG_PATH=" + cfgPath);
	/* The runtime's HAL carries a local patch that reads this (the config
	 * knob is validated in loadConfig; re-exported so the value the child
	 * sees is always the one the daemon logged). */
	envs.push_back("HPCAM_NR_STRENGTH=" + std::to_string(cfg_.nrStrength));
	if (!rundir_.empty())
		envs.push_back("GST_REGISTRY=" + rundir_ + "/gst-registry.bin");
	std::vector<char *> envp;
	for (auto &s : envs)
		envp.push_back(s.data());
	envp.push_back(nullptr);

	/* Frames go to fd 3, never stdout: CamHAL and GStreamer both log to
	 * stdout, and one stray line in a raw NV12 stream desyncs everything
	 * after it. -q silences gst-launch's own progress chatter anyway. */
	std::vector<char *> argvp;
	for (auto &s : args)
		argvp.push_back(s.data());
	argvp.push_back(nullptr);

	pid_t pid = fork();
	if (pid < 0) {
		logf("fork: %s", strerror(errno));
		close(pfd[0]);
		close(pfd[1]);
		return false;
	}
	if (pid == 0) {
		/* Child. In camhal mode no libcamera threads exist, so this is
		 * a single-threaded fork and the libc calls below are safe. If
		 * the daemon dies without cleanup, take CamHAL down with it
		 * rather than leave it holding the IPU7 nodes. */
		prctl(PR_SET_PDEATHSIG, SIGKILL);
		/* SIG_IGN survives execve; give gst-launch its SIGPIPE back so
		 * a vanished reader kills it instead of looping on EPIPE. */
		signal(SIGPIPE, SIG_DFL);
		if (pfd[1] == 3)
			fcntl(3, F_SETFD, 0);	/* clear CLOEXEC in place */
		else if (dup2(pfd[1], 3) < 0)
			_exit(127);
		dup2(2, 1);	/* CamHAL logs on stdout -> the journal */
		execve("/usr/bin/gst-launch-1.0", argvp.data(), envp.data());
		_exit(127);
	}
	close(pfd[1]);
	gstPid_ = pid;
	gstFd_ = pfd[0];
	gstEof_ = false;
	sessionFrames_ = 0;
	lastCameraFrame_ = monoMs();
	gstThread_ = std::thread(&Daemon::camhalReader, this);
	logf("consumer present — camhal engine started (pid %d): %s "
	     "(sensor on, LED on), nr_strength=%d denoise=%g",
	     (int)pid, pipeline.c_str(), cfg_.nrStrength, cfg_.denoise);
	return true;
}

void Daemon::camhalStop(const char *why)
{
	if (gstPid_ > 0) {
		/* SIGKILL, never SIGTERM: a wedged CamHAL that is merely TERM'd
		 * keeps the IPU7 device nodes open and poisons every later
		 * attempt (recovery-ladder record, 2026-08-05/06). */
		kill(gstPid_, SIGKILL);
		int st = 0;
		waitpid(gstPid_, &st, 0);
		if (WIFEXITED(st))
			logf("camhal subprocess had already exited with status %d",
			     WEXITSTATUS(st));
		else if (WIFSIGNALED(st) && WTERMSIG(st) != SIGKILL)
			logf("camhal subprocess had died on signal %d", WTERMSIG(st));
		gstPid_ = -1;
	}
	/* The child's death closed the pipe's write end, so the reader sees
	 * EOF and exits; join cannot hang. Close our end only after the join —
	 * the reader owns gstFd_ until then. */
	if (gstThread_.joinable())
		gstThread_.join();
	if (gstFd_ >= 0) {
		close(gstFd_);
		gstFd_ = -1;
	}
	logf("%s — camhal engine stopped, sensor off (LED off), feeding black", why);
}

int Daemon::run()
{
	self_ = getpid();

	MediaGraph graph;
	if (!findGraph(graph)) {
		logf("no intel-ipu7 media device found — is intel-ipu7-drivers "
		     "installed and loaded?");
		return 1;
	}
	const MediaEntity *sensor = graph.findByPrefix("ov05c10");
	if (!sensor) {
		logf("no ov05c10 sensor entity on %s — the sensor driver did not "
		     "bind. Check: dmesg | grep -i ov05c10, and that ACPI device "
		     "OVTI05C1 is present",
		     graph.device.c_str());
		return 1;
	}
	{
		std::string chain = sensor->name + " (" + sensor->devnode + ")";
		uint32_t id = sensor->id;
		for (int hop = 0; hop < 4; hop++) {
			auto it = graph.links.find(id);
			if (it == graph.links.end())
				break;
			const MediaEntity *next = graph.byId(it->second);
			if (!next)
				break;
			chain += " -> " + next->name;
			if (!next->devnode.empty())
				chain += " (" + next->devnode + ")";
			id = next->id;
		}
		logf("graph: %s: %s -> %s", graph.device.c_str(), chain.c_str(),
		     cfg_.loop.c_str());
	}

	/* Same place the bash daemon keeps its runtime state: a fixed name in a
	 * root-owned 0700 directory, provided by the unit's RuntimeDirectory. */
	rundir_ = envStr("RUNTIME_DIRECTORY", envStr("RUNDIR", ""));
	if (!rundir_.empty()) {
		mkdir(rundir_.c_str(), 0700);
		chmod(rundir_.c_str(), 0700);
	}

	makeBlackFrame();
	if (!openLoopback())
		return 1;

	engine_ = cfg_.engine;
	if (engine_ == Engine::CamHal) {
		std::string plugin =
			cfg_.camhalPrefix + "/lib/gstreamer-1.0/libgsticamerasrc.so";
		if (access(kCamhalFallbackFlag, F_OK) == 0 && !cfg_.engineForced) {
			logf("camhal fallback flag %s present — starting on the "
			     "SoftISP engine (rm the flag and restart the service "
			     "to re-arm CamHAL)", kCamhalFallbackFlag);
			engine_ = Engine::SoftIsp;
			camhalFellBack_ = true;
		} else if (access(plugin.c_str(), F_OK) != 0) {
			logf("camhal runtime incomplete (%s missing) — is "
			     "hp-elitebook-x-g2i-camhal-runtime installed? Using "
			     "the SoftISP engine.", plugin.c_str());
			engine_ = Engine::SoftIsp;
		} else {
			logf("engine: camhal (runtime %s, sensor %s), softisp "
			     "fallback armed", cfg_.camhalPrefix.c_str(),
			     cfg_.camhalSensor.c_str());
		}
	} else {
		logf("engine: softisp (HPCAM_ENGINE override)");
	}

	/* In camhal mode libcamera must not start at all — the simple pipeline
	 * handler opens every media-graph entity while enumerating, and two ISP
	 * stacks holding IPU7 nodes at once is the kind of sharing this
	 * hardware punishes. softispStart() initialises it lazily instead. */
	if (engine_ == Engine::SoftIsp && !cameraInit())
		return 1;

	/* Take the output token immediately: until a frame has been written the
	 * loopback still advertises OUTPUT and Chrome will not list it. */
	writeFrame(black_.data(), black_.size());
	startedAt_ = stateSince_ = monoMs();
	reason_ = "startup, no consumer yet";
	logf("ready — writer attached to %s (capture-only advertised), sensor off",
	     cfg_.loop.c_str());
	publishStatus();
	logf("%s", statusLine().c_str());

	uint64_t lastPoll = 0, lastBlack = 0, lastHeartbeat = monoMs();
	int idleFor = 0;
	int backoffMs = 0;
	uint64_t backoffUntil = 0;
	fpsWindowStart_ = monoMs();

	while (!g_stop) {
		usleep(50000);
		uint64_t now = monoMs();

		if (writeFailed_) {
			logf("loopback write failed — exiting so systemd restarts us");
			break;
		}
		if (fatal_)
			break;

		if (state_ == State::Idle && now - lastBlack >= (uint64_t)cfg_.blackMs) {
			writeFrame(black_.data(), black_.size());
			lastBlack = now;
		}

		if (state_ == State::Active) {
			const bool camhal = engine_ == Engine::CamHal;
			/* Engine A has one extra failure mode the frame timeout
			 * would catch 5 s late: the subprocess dying outright.
			 * And its start deadline is its own, because CamHAL
			 * legitimately takes ~2 s to the first frame (longer on
			 * the first run of a boot while gst builds a registry). */
			const bool exited = camhal && gstEof_.load();
			uint64_t tmo = (uint64_t)cfg_.frameTimeoutMs;
			if (camhal && sessionFrames_.load() == 0)
				tmo = (uint64_t)cfg_.camhalStartMs;
			if (camhal && camhalFailures_ > 0 &&
			    sessionFrames_.load() >= 30) {
				logf("camhal delivering again — failure count reset");
				camhalFailures_ = 0;
			}
			if (exited || now - lastCameraFrame_.load() > tmo) {
				backoffMs = backoffMs ? std::min(backoffMs * 2, 30000)
						      : 2000;
				backoffUntil = now + backoffMs;
				char why[128];
				if (exited)
					snprintf(why, sizeof(why),
						 "camhal subprocess exited after %llu frames, retrying in %dms",
						 (unsigned long long)sessionFrames_.load(),
						 backoffMs);
				else
					snprintf(why, sizeof(why),
						 "no sensor frame for %llus, retrying in %dms",
						 (unsigned long long)(tmo / 1000),
						 backoffMs);
				engineStop(why);
				if (camhal)
					camhalAccountFailure(
						exited ? "subprocess exited" :
						sessionFrames_.load() ? "frame stall" :
									"no first frame");
				state_ = State::Idle;
				stateSince_ = now;
				reason_ = why;
				sensorFailures_++;
				lastBlack = 0;
				publishStatus();
				logf("%s", statusLine().c_str());
				continue;
			}
		}

		if (now - lastPoll < (uint64_t)cfg_.pollMs)
			continue;
		lastPoll = now;

		/* Frame rate over the poll window, for the status line only. */
		uint64_t frames = cameraFrames_.load();
		if (now > fpsWindowStart_)
			fps_ = (frames - fpsWindowFrames_) * 1000.0 /
			       (now - fpsWindowStart_);
		fpsWindowStart_ = now;
		fpsWindowFrames_ = frames;

		consumers_ = countConsumers();
		bool transitioned = false;

		if (consumers_ > 0) {
			idleFor = 0;
			if (state_ == State::Idle && now >= backoffUntil) {
				sensorStarts_++;
				if (engineStart()) {
					state_ = State::Active;
					stateSince_ = monoMs();
					if (engine_ == Engine::CamHal) {
						/* CamHAL runs the sensor at its
						 * native mode internally and
						 * delivers the output size. */
						sensorW_ = cfg_.outW;
						sensorH_ = cfg_.outH;
					} else {
						sensorW_ = srcW_;
						sensorH_ = srcH_;
					}
					reason_ = "consumer reading the loopback";
					backoffMs = 0;
					transitioned = true;
				} else {
					sensorFailures_++;
					if (engine_ == Engine::CamHal)
						camhalAccountFailure("engine failed to start");
					backoffMs = backoffMs ? std::min(backoffMs * 2, 30000)
							      : 2000;
					backoffUntil = monoMs() + backoffMs;
					reason_ = "sensor start failed, on black";
					logf("sensor start failed — staying on black, "
					     "retrying in %d ms", backoffMs);
					transitioned = true;
				}
			}
		} else if (state_ == State::Active) {
			idleFor += std::max(cfg_.pollMs / 1000, 1);
			if (idleFor >= cfg_.idleStop) {
				char why[80];
				snprintf(why, sizeof(why), "no consumers for %ds", idleFor);
				engineStop(why);
				state_ = State::Idle;
				stateSince_ = monoMs();
				reason_ = why;
				lastBlack = 0;
				idleFor = 0;
				transitioned = true;
			}
		}

		publishStatus();
		if (transitioned ||
		    (cfg_.statusLogS > 0 &&
		     now - lastHeartbeat >= (uint64_t)cfg_.statusLogS * 1000) ||
		    g_status.exchange(false)) {
			logf("%s", statusLine().c_str());
			lastHeartbeat = now;
		}
	}

	if (state_ == State::Active)
		engineStop("shutting down");
	state_ = State::Idle;
	reason_ = "stopped";
	publishStatus();
	/* Drop the last reference to the Camera before stopping the manager, or
	 * libcamera logs "Removing media device /dev/media0 while still in use"
	 * on the way out. */
	stream_ = nullptr;
	camera_.reset();
	if (cm_)
		cm_->stop();
	if (loopFd_ >= 0)
		close(loopFd_);
	logf("stopped after %llu sensor frames, %u sensor starts, %u failures",
	     (unsigned long long)cameraFrames_.load(), sensorStarts_, sensorFailures_);
	return (writeFailed_ || fatal_) ? 1 : 0;
}

} /* namespace */

int main()
{
	signal(SIGINT, onSignal);
	signal(SIGTERM, onSignal);
	signal(SIGUSR1, onStatusSignal);
	signal(SIGPIPE, SIG_IGN);
	setvbuf(stderr, nullptr, _IOLBF, 0);

	Config cfg = loadConfig();
	Daemon d(cfg);
	return d.run();
}
