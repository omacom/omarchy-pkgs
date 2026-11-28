#define _GNU_SOURCE
#include "control-client.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

/* Passive persistence: never replace a live application. No history or disk IO. */
#define MAX_TYPES 64
#define MAX_BYTES (32u * 1024u * 1024u)
#define MAX_RESIDENT (64u * 1024u * 1024u)
#define READ_MS 2000
#define WRITE_MS 5000
#define SETTLE_MS 80
#define PROBE_MS 100
#define MAX_WRITERS 32

struct blob {
  char *mime;
  unsigned char *data;
  size_t size, capacity;
  int fd;
  bool done;
};
struct snapshot {
  int refs;
  size_t count, total;
  int64_t deadline;
  struct blob blobs[MAX_TYPES];
};
struct offer {
  struct ext_data_control_offer_v1 *proxy;
  size_t count;
  bool sensitive, overflow, own;
  char *types[MAX_TYPES];
};
struct source {
  struct ext_data_control_source_v1 *proxy;
  struct snapshot *snapshot;
};
struct writer {
  int fd;
  size_t offset;
  struct blob *blob;
  struct snapshot *snapshot;
  int64_t deadline;
};
static struct wl_display *display;
static struct wl_seat *seat;
static struct ext_data_control_manager_v1 *manager;
static struct ext_data_control_device_v1 *device;
static struct offer *selection;
static struct snapshot *cache;
static struct source *source;
static struct writer writers[MAX_WRITERS];
static bool empty, finished;
static int64_t empty_since;
static uint64_t revision, fence_revision;
static struct wl_callback *fence;
static struct ext_data_control_device_v1 *probe;
static struct wl_callback *probe_fence;
static uint64_t probe_revision;
static bool probe_seen, probe_empty, probe_valid;
static int64_t next_probe;
static char marker[128];
static size_t allocated_bytes;
static volatile sig_atomic_t stop_requested, clear_requested;
static bool complete(void);

static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void signal_received(int sig) {
  if (sig == SIGUSR1)
    clear_requested = 1;
  else
    stop_requested = 1;
}
static void *allocate(size_t size) {
  void *p = calloc(1, size);
  if (!p) {
    fputs("omarchy-clipboard-keeper: out of memory\n", stderr);
    exit(1);
  }
  return p;
}
static void release(struct snapshot *s) {
  if (!s || --s->refs)
    return;
  for (size_t i = 0; i < s->count; i++) {
    struct blob *b = &s->blobs[i];
    if (b->fd >= 0)
      close(b->fd);
    if (b->data) {
      allocated_bytes -= b->capacity;
      explicit_bzero(b->data, b->capacity);
      free(b->data);
    }
    free(b->mime);
  }
  free(s);
}
static void discard_cache(void) {
  release(cache);
  cache = NULL;
}
static void destroy_offer(struct offer *o) {
  if (!o)
    return;
  ext_data_control_offer_v1_destroy(o->proxy);
  for (size_t i = 0; i < o->count; i++)
    free(o->types[i]);
  free(o);
}
static bool supported(const char *mime) {
  static const char *types[] = {"text/plain",
                                "text/html",
                                "text/uri-list",
                                "text/markdown",
                                "text/rtf",
                                "UTF8_STRING",
                                "STRING",
                                "TEXT",
                                "COMPOUND_TEXT",
                                "image/png",
                                "image/jpeg",
                                "image/webp",
                                "image/gif",
                                "image/bmp",
                                "image/tiff",
                                "image/svg+xml",
                                "application/rtf",
                                "application/x-qt-image",
                                "x-special/gnome-copied-files",
                                "application/x-kde-cutselection",
                                NULL};
  for (size_t i = 0; types[i]; i++) {
    size_t n = strlen(types[i]);
    if (!strncmp(mime, types[i], n) && (!mime[n] || mime[n] == ';'))
      return true;
  }
  return false;
}
static void offer_type(void *data, struct ext_data_control_offer_v1 *proxy, const char *mime) {
  struct offer *o = data;
  if (!strcmp(mime, marker))
    o->own = true;
  if (!strcmp(mime, "x-kde-passwordManagerHint") ||
      !strcmp(mime, "application/x-kde-passwordManagerHint") ||
      !strcmp(mime, "application/x-keepassxc") ||
      !strcmp(mime, "application/x-kde-onlyReplaceEmpty"))
    o->sensitive = true;
  if (!supported(mime))
    return;
  for (size_t i = 0; i < o->count; i++)
    if (!strcmp(o->types[i], mime))
      return;
  if (o->count == MAX_TYPES) {
    o->overflow = true;
    return;
  }
  o->types[o->count] = strdup(mime);
  if (!o->types[o->count])
    exit(1);
  o->count++;
}
static const struct ext_data_control_offer_v1_listener offer_listener = {.offer = offer_type};
static void new_offer(void *data, struct ext_data_control_device_v1 *dev,
                      struct ext_data_control_offer_v1 *proxy) {
  struct offer *o = allocate(sizeof(*o));
  o->proxy = proxy;
  ext_data_control_offer_v1_add_listener(proxy, &offer_listener, o);
}
static void selected(void *data, struct ext_data_control_device_v1 *dev,
                     struct ext_data_control_offer_v1 *proxy) {
  revision++;
  destroy_offer(selection);
  selection = proxy ? wl_proxy_get_user_data((struct wl_proxy *)proxy) : NULL;
  empty = !proxy;
  empty_since = now_ms();
  if (!selection) {
    /* An owner killed mid-stream can close a pipe with truncated bytes.
     * Only snapshots completed BEFORE owner loss are safe to restore. */
    if (!complete())
      discard_cache();
    return;
  }
  if (selection->own)
    return;
  discard_cache(); /* Never resurrect an older copy after a failed new one. */
  if (selection->sensitive || selection->overflow || !selection->count)
    return;
  cache = allocate(sizeof(*cache));
  cache->refs = 1;
  cache->deadline = now_ms() + READ_MS;
  cache->count = selection->count;
  for (size_t i = 0; i < cache->count; i++)
    cache->blobs[i].fd = -1;
  for (size_t i = 0; i < cache->count; i++) {
    struct blob *b = &cache->blobs[i];
    b->mime = strdup(selection->types[i]);
    int fds[2];
    if (!b->mime || pipe2(fds, O_CLOEXEC) < 0) {
      discard_cache();
      return;
    }
    /* Only the reader is nonblocking; applications get a normal write FD. */
    if (fcntl(fds[0], F_SETFL, O_NONBLOCK) < 0) {
      close(fds[0]);
      close(fds[1]);
      discard_cache();
      return;
    }
    b->fd = fds[0];
    ext_data_control_offer_v1_receive(proxy, b->mime, fds[1]);
    close(fds[1]);
  }
}
static void primary_selected(void *data, struct ext_data_control_device_v1 *dev,
                             struct ext_data_control_offer_v1 *proxy) {
  if (proxy)
    destroy_offer(wl_proxy_get_user_data((struct wl_proxy *)proxy));
}
static void device_finished(void *data, struct ext_data_control_device_v1 *dev) { finished = true; }
static const struct ext_data_control_device_v1_listener device_listener = {
    .data_offer = new_offer,
    .selection = selected,
    .finished = device_finished,
    .primary_selection = primary_selected};
/* Hyprland 0.56 can omit selection(NULL) when an owner disconnects. A fresh
 * data device still receives the correct initial selection. Probe metadata
 * only: no repeated payload reads and no taking over a live source. */
static void probe_selected(void *data, struct ext_data_control_device_v1 *dev,
                           struct ext_data_control_offer_v1 *proxy) {
  probe_seen = true;
  probe_empty = !proxy;
  if (proxy)
    destroy_offer(wl_proxy_get_user_data((struct wl_proxy *)proxy));
}
static void probe_finished(void *data, struct ext_data_control_device_v1 *dev) {
  probe_valid = false;
}
static const struct ext_data_control_device_v1_listener probe_listener = {
    .data_offer = new_offer,
    .selection = probe_selected,
    .finished = probe_finished,
    .primary_selection = primary_selected};
static void probe_done(void *data, struct wl_callback *cb, uint32_t serial) {
  wl_callback_destroy(cb);
  probe_fence = NULL;
  ext_data_control_device_v1_destroy(probe);
  probe = NULL;
  if (probe_seen && probe_empty && probe_valid && probe_revision == revision && selection &&
      !source)
    selected(NULL, device, NULL);
}
static const struct wl_callback_listener probe_fence_listener = {.done = probe_done};
static bool needs_probe(void) { return selection && !source && complete() && !empty; }
static void close_writer(struct writer *w) {
  if (w->fd >= 0)
    close(w->fd);
  release(w->snapshot);
  memset(w, 0, sizeof(*w));
  w->fd = -1;
}
static void send_data(void *data, struct ext_data_control_source_v1 *proxy, const char *mime,
                      int32_t fd) {
  struct source *s = data;
  struct blob *b = NULL;
  for (size_t i = 0; i < s->snapshot->count; i++) {
    if (!strcmp(s->snapshot->blobs[i].mime, mime))
      b = &s->snapshot->blobs[i];
  }
  if (!b || fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
    close(fd);
    return;
  }
  for (size_t i = 0; i < MAX_WRITERS; i++) {
    if (writers[i].fd >= 0)
      continue;
    writers[i] = (struct writer){
        .fd = fd, .blob = b, .snapshot = s->snapshot, .deadline = now_ms() + WRITE_MS};
    s->snapshot->refs++;
    return;
  }
  close(fd);
}
static void source_cancelled(void *data, struct ext_data_control_source_v1 *proxy) {
  struct source *s = data;
  if (source == s)
    source = NULL;
  ext_data_control_source_v1_destroy(proxy);
  release(s->snapshot);
  free(s);
}
static const struct ext_data_control_source_v1_listener source_listener = {
    .send = send_data, .cancelled = source_cancelled};
static bool complete(void) {
  if (!cache)
    return false;
  for (size_t i = 0; i < cache->count; i++)
    if (!cache->blobs[i].done)
      return false;
  return true;
}
static void restore_ready(void *data, struct wl_callback *cb, uint32_t serial) {
  wl_callback_destroy(cb);
  fence = NULL;
  if (!empty || fence_revision != revision || !complete() || source)
    return;
  source = allocate(sizeof(*source));
  source->snapshot = cache;
  cache->refs++;
  source->proxy = ext_data_control_manager_v1_create_data_source(manager);
  ext_data_control_source_v1_add_listener(source->proxy, &source_listener, source);
  for (size_t i = 0; i < cache->count; i++)
    ext_data_control_source_v1_offer(source->proxy, cache->blobs[i].mime);
  ext_data_control_source_v1_offer(source->proxy, marker);
  ext_data_control_device_v1_set_selection(device, source->proxy);
  empty = false;
}
static const struct wl_callback_listener fence_listener = {.done = restore_ready};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface,
                   uint32_t version) {
  if (!strcmp(interface, "wl_seat") && !seat)
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
  if (!strcmp(interface, "ext_data_control_manager_v1") && !manager)
    manager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_listener = {.global = global,
                                                              .global_remove = removed};

/* Returns false on timeout, oversize, IO error, or failed allocation. */
static bool read_blob(struct snapshot *s, struct blob *b) {
  unsigned char buf[65536];
  size_t budget = 256 * 1024; /* Give display events and other pipes a turn. */
  while (budget) {
    size_t amount = budget < sizeof(buf) ? budget : sizeof(buf);
    ssize_t n = read(b->fd, buf, amount);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
      return true;
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0)
      return false;
    if (!n) {
      close(b->fd);
      b->fd = -1;
      b->done = true;
      return true;
    }
    if ((size_t)n > MAX_BYTES - s->total)
      return false;
    size_t needed = b->size + (size_t)n;
    if (needed > b->capacity) {
      size_t capacity = needed; /* No hidden doubling beyond the byte cap. */
      if (capacity - b->capacity > MAX_RESIDENT - allocated_bytes)
        return false;
      unsigned char *next = realloc(b->data, capacity);
      if (!next)
        return false;
      allocated_bytes += capacity - b->capacity;
      b->data = next;
      b->capacity = capacity;
    }
    memcpy(b->data + b->size, buf, (size_t)n);
    b->size += (size_t)n;
    s->total += (size_t)n;
    budget -= (size_t)n;
  }
  return true;
}
static void read_cache(void) {
  if (!cache || complete())
    return;
  if (now_ms() >= cache->deadline) {
    fputs("omarchy-clipboard-keeper: dropped stalled copy\n", stderr);
    discard_cache();
    return;
  }
  for (size_t i = 0; cache && i < cache->count; i++) {
    struct blob *b = &cache->blobs[i];
    if (b->fd >= 0 && !read_blob(cache, b)) {
      fputs("omarchy-clipboard-keeper: dropped incomplete or oversized copy\n", stderr);
      discard_cache();
      return;
    }
  }
}
static void write_pending(void) {
  for (size_t i = 0; i < MAX_WRITERS; i++) {
    struct writer *w = &writers[i];
    if (w->fd < 0)
      continue;
    if (now_ms() >= w->deadline) {
      close_writer(w);
      continue;
    }
    size_t remaining = w->blob->size - w->offset;
    if (!remaining) {
      close_writer(w);
      continue;
    }
    if (remaining > 65536)
      remaining = 65536;
    ssize_t n = write(w->fd, w->blob->data + w->offset, remaining);
    if (n > 0)
      w->offset += (size_t)n;
    else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
      close_writer(w);
    if (w->fd >= 0 && w->offset == w->blob->size)
      close_writer(w);
  }
}
static void clear_clipboard(void) {
  clear_requested = 0;
  revision++;
  discard_cache();
  if (source)
    source_cancelled(source, source->proxy);
  ext_data_control_device_v1_set_selection(device, NULL);
  for (size_t i = 0; i < MAX_WRITERS; i++)
    if (writers[i].fd >= 0)
      close_writer(&writers[i]);
}
int main(void) {
  umask(0077);
  const char *runtime = getenv("XDG_RUNTIME_DIR");
  int lock_fd = -1;
  if (runtime) {
    char path[4096];
    if (snprintf(path, sizeof(path), "%s/omarchy-clipboard-keeper.lock", runtime) >=
        (int)sizeof(path))
      return 1;
    lock_fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock_fd < 0) {
      perror("omarchy-clipboard-keeper: lock");
      return 1;
    }
    if (flock(lock_fd, LOCK_EX | LOCK_NB) < 0)
      return 0;
  }
  /* Clipboard bytes must not appear in crash dumps. */
  const struct rlimit no_core = {0, 0};
  (void)setrlimit(RLIMIT_CORE, &no_core);
  (void)prctl(PR_SET_DUMPABLE, 0);
  for (size_t i = 0; i < MAX_WRITERS; i++)
    writers[i].fd = -1;
  struct sigaction action = {.sa_handler = signal_received};
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGUSR1, &action, NULL);
  signal(SIGPIPE, SIG_IGN);
  snprintf(marker, sizeof(marker), "application/x-local-omarchy-clipboard-keeper-%ld",
           (long)getpid());
  display = wl_display_connect(NULL);
  if (!display) {
    perror("omarchy-clipboard-keeper: Wayland connection");
    return 1;
  }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  if (wl_display_roundtrip(display) < 0 || !seat || !manager) {
    fputs("omarchy-clipboard-keeper: ext-data-control and a seat are required\n", stderr);
    return 1;
  }
  device = ext_data_control_manager_v1_get_data_device(manager, seat);
  ext_data_control_device_v1_add_listener(device, &device_listener, NULL);
  fputs("omarchy-clipboard-keeper: ready (passive, memory only)\n", stderr);
  while (!stop_requested && !finished) {
    /* Single-threaded: drain events before deciding to restore or handling IO. */
    if (wl_display_dispatch_pending(display) < 0)
      break;
    if (clear_requested)
      clear_clipboard();
    read_cache();
    write_pending();
    if (empty && complete() && !source && !fence && now_ms() - empty_since >= SETTLE_MS) {
      fence_revision = revision;
      fence = wl_display_sync(display);
      wl_callback_add_listener(fence, &fence_listener, NULL);
    }
    if (needs_probe() && !probe && now_ms() >= next_probe) {
      next_probe = now_ms() + PROBE_MS;
      probe_revision = revision;
      probe_seen = false;
      probe_empty = false;
      probe_valid = true;
      probe = ext_data_control_manager_v1_get_data_device(manager, seat);
      ext_data_control_device_v1_add_listener(probe, &probe_listener, NULL);
      probe_fence = wl_display_sync(display);
      wl_callback_add_listener(probe_fence, &probe_fence_listener, NULL);
    }
    int result = wl_display_flush(display);
    if (result < 0 && errno != EAGAIN)
      break;
    struct pollfd fds[1 + MAX_TYPES + MAX_WRITERS];
    nfds_t count = 0;
    fds[count++] = (struct pollfd){.fd = wl_display_get_fd(display),
                                   .events = POLLIN | (result < 0 ? POLLOUT : 0)};
    if (cache)
      for (size_t i = 0; i < cache->count; i++) {
        if (cache->blobs[i].fd >= 0)
          fds[count++] = (struct pollfd){.fd = cache->blobs[i].fd, .events = POLLIN};
      }
    for (size_t i = 0; i < MAX_WRITERS; i++) {
      if (writers[i].fd >= 0)
        fds[count++] = (struct pollfd){.fd = writers[i].fd, .events = POLLOUT};
    }
    int timeout = 1000;
    int64_t now = now_ms();
    if (cache && !complete()) {
      int64_t left = cache->deadline - now;
      if (left < timeout)
        timeout = left > 0 ? (int)left : 0;
    }
    for (size_t i = 0; i < MAX_WRITERS; i++)
      if (writers[i].fd >= 0) {
        int64_t left = writers[i].deadline - now;
        if (left < timeout)
          timeout = left > 0 ? (int)left : 0;
      }
    if (empty && complete() && !source && !fence) {
      int64_t left = empty_since + SETTLE_MS - now;
      if (left < timeout)
        timeout = left > 0 ? (int)left : 0;
    }
    if (needs_probe() && !probe) {
      int64_t left = next_probe - now;
      if (left < timeout)
        timeout = left > 0 ? (int)left : 0;
    }
    result = poll(fds, count, timeout);
    if (result < 0 && errno != EINTR)
      break;
    if (result > 0 && (fds[0].revents & (POLLIN | POLLHUP | POLLERR)))
      if (wl_display_dispatch(display) < 0)
        break;
  }
  if (fence)
    wl_callback_destroy(fence);
  if (probe_fence)
    wl_callback_destroy(probe_fence);
  if (probe)
    ext_data_control_device_v1_destroy(probe);
  for (size_t i = 0; i < MAX_WRITERS; i++)
    if (writers[i].fd >= 0)
      close_writer(&writers[i]);
  if (source)
    source_cancelled(source, source->proxy);
  discard_cache();
  destroy_offer(selection);
  ext_data_control_device_v1_destroy(device);
  ext_data_control_manager_v1_destroy(manager);
  wl_seat_destroy(seat);
  wl_registry_destroy(registry);
  wl_display_flush(display);
  wl_display_disconnect(display);
  if (lock_fd >= 0)
    close(lock_fd);
  return stop_requested ? 0 : 1;
}
