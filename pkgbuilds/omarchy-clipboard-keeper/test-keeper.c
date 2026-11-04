#define _GNU_SOURCE
#include "control-server.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server.h>

/* A real libwayland server on a socketpair: never touches the user's clipboard. */
struct payload {
  const char *mime;
  const void *data;
  size_t size;
  bool stall;
};
struct offer {
  struct payload payloads[65];
  size_t count;
};
struct source {
  struct wl_resource *resource;
  char *types[65];
  size_t count;
};
struct transfer {
  struct wl_event_source *event;
  int fd;
  const unsigned char *data;
  size_t size, offset;
  struct transfer *next;
};
static struct wl_display *display;
static struct wl_event_loop *loop;
static struct wl_resource *device;
static struct source *current;
static struct transfer *transfers;
static pid_t child;
static unsigned restores;
static bool external_active;
static struct payload active_payloads[65];
static size_t active_count;
static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void pump(int ms) {
  int64_t end = now_ms() + ms;
  do {
    wl_display_flush_clients(display);
    wl_event_loop_dispatch(loop, 5);
  } while (now_ms() < end);
  wl_display_flush_clients(display);
}
static void destroy_resource(struct wl_client *client, struct wl_resource *resource) {
  wl_resource_destroy(resource);
}
static void finish_transfer(struct transfer *t) {
  close(t->fd);
  t->fd = -1;
  if (t->event) {
    wl_event_source_remove(t->event);
    t->event = NULL;
  }
}
static int write_transfer(int fd, uint32_t mask, void *data) {
  struct transfer *t = data;
  if (t->offset == t->size) {
    finish_transfer(t);
    return 0;
  }
  ssize_t n = write(fd, t->data + t->offset, t->size - t->offset);
  if (n > 0)
    t->offset += (size_t)n;
  else if (n < 0 && errno != EAGAIN && errno != EINTR)
    finish_transfer(t);
  if (t->fd >= 0 && t->offset == t->size)
    finish_transfer(t);
  return 0;
}
static void offer_receive(struct wl_client *client, struct wl_resource *resource, const char *mime,
                          int32_t fd) {
  struct offer *o = wl_resource_get_user_data(resource);
  for (size_t i = 0; i < o->count; i++) {
    struct payload *p = &o->payloads[i];
    if (strcmp(p->mime, mime))
      continue;
    struct transfer *t = calloc(1, sizeof(*t));
    assert(t);
    *t = (struct transfer){.fd = fd, .data = p->data, .size = p->size, .next = transfers};
    transfers = t;
    assert(fcntl(fd, F_SETFL, O_NONBLOCK) == 0);
    if (!p->stall)
      t->event = wl_event_loop_add_fd(loop, fd, WL_EVENT_WRITABLE, write_transfer, t);
    return;
  }
  close(fd);
}
static const struct ext_data_control_offer_v1_interface offer_impl = {.receive = offer_receive,
                                                                      .destroy = destroy_resource};
static void offer_destroyed(struct wl_resource *resource) {
  free(wl_resource_get_user_data(resource));
}
static struct wl_resource *make_offer(struct wl_resource *target, struct payload *payloads,
                                      size_t count) {
  struct wl_resource *resource = wl_resource_create(wl_resource_get_client(target),
                                                    &ext_data_control_offer_v1_interface, 1, 0);
  struct offer *o = calloc(1, sizeof(*o));
  assert(o && count <= 65);
  o->count = count;
  memcpy(o->payloads, payloads, count * sizeof(*payloads));
  wl_resource_set_implementation(resource, &offer_impl, o, offer_destroyed);
  ext_data_control_device_v1_send_data_offer(target, resource);
  for (size_t i = 0; i < count; i++)
    ext_data_control_offer_v1_send_offer(resource, payloads[i].mime);
  return resource;
}
static void cancel_current(void) {
  if (current)
    ext_data_control_source_v1_send_cancelled(current->resource);
  current = NULL;
}
static void external_copy(struct payload *payloads, size_t count) {
  cancel_current();
  external_active = true;
  active_count = count;
  memcpy(active_payloads, payloads, count * sizeof(*payloads));
  ext_data_control_device_v1_send_selection(device, make_offer(device, payloads, count));
}
static void owner_closed(void) {
  external_active = false;
  cancel_current();
  ext_data_control_device_v1_send_selection(device, NULL);
}
static void source_offer(struct wl_client *client, struct wl_resource *resource, const char *mime) {
  struct source *s = wl_resource_get_user_data(resource);
  assert(s->count < 65);
  s->types[s->count++] = strdup(mime);
}
static void source_destroyed(struct wl_resource *resource) {
  struct source *s = wl_resource_get_user_data(resource);
  if (current == s)
    current = NULL;
  for (size_t i = 0; i < s->count; i++)
    free(s->types[i]);
  free(s);
}
static const struct ext_data_control_source_v1_interface source_impl = {
    .offer = source_offer, .destroy = destroy_resource};
static void create_source(struct wl_client *client, struct wl_resource *resource, uint32_t id) {
  struct source *s = calloc(1, sizeof(*s));
  assert(s);
  s->resource = wl_resource_create(client, &ext_data_control_source_v1_interface, 1, id);
  wl_resource_set_implementation(s->resource, &source_impl, s, source_destroyed);
}
static void set_selection(struct wl_client *client, struct wl_resource *resource,
                          struct wl_resource *src) {
  cancel_current();
  external_active = false;
  if (!src) {
    ext_data_control_device_v1_send_selection(device, NULL);
    return;
  }
  current = wl_resource_get_user_data(src);
  restores++;
  struct payload payloads[65] = {0};
  for (size_t i = 0; i < current->count; i++)
    payloads[i].mime = current->types[i];
  ext_data_control_device_v1_send_selection(device, make_offer(device, payloads, current->count));
}
static void set_primary(struct wl_client *client, struct wl_resource *resource,
                        struct wl_resource *src) {
  assert(!"must not alter primary selection");
}
static const struct ext_data_control_device_v1_interface device_impl = {
    .set_selection = set_selection,
    .destroy = destroy_resource,
    .set_primary_selection = set_primary};
static void get_device(struct wl_client *client, struct wl_resource *resource, uint32_t id,
                       struct wl_resource *seat) {
  struct wl_resource *target =
      wl_resource_create(client, &ext_data_control_device_v1_interface, 1, id);
  if (!device)
    device = target;
  wl_resource_set_implementation(target, &device_impl, NULL, NULL);
  if (external_active)
    ext_data_control_device_v1_send_selection(target,
                                              make_offer(target, active_payloads, active_count));
  else if (current) {
    struct payload payloads[65] = {0};
    for (size_t i = 0; i < current->count; i++)
      payloads[i].mime = current->types[i];
    ext_data_control_device_v1_send_selection(target, make_offer(target, payloads, current->count));
  } else
    ext_data_control_device_v1_send_selection(target, NULL);
  ext_data_control_device_v1_send_primary_selection(target, NULL);
}
static const struct ext_data_control_manager_v1_interface manager_impl = {
    .create_data_source = create_source,
    .get_data_device = get_device,
    .destroy = destroy_resource};
static void bind_manager(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
  struct wl_resource *r = wl_resource_create(client, &ext_data_control_manager_v1_interface, 1, id);
  wl_resource_set_implementation(r, &manager_impl, NULL, NULL);
}
static void bind_seat(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
  struct wl_resource *r = wl_resource_create(client, &wl_seat_interface, 1, id);
  wl_seat_send_capabilities(r, 0);
}
static void expect_restored(struct payload *payloads, size_t count) {
  int64_t deadline = now_ms() + 1500;
  while (!current && now_ms() < deadline)
    pump(10);
  assert(current && current->count == count + 1); /* includes our loop marker */
  for (size_t i = 0; i < count; i++) {
    bool offered = false;
    for (size_t j = 0; j < current->count; j++)
      if (!strcmp(payloads[i].mime, current->types[j]))
        offered = true;
    assert(offered);
    int fds[2];
    assert(pipe2(fds, O_CLOEXEC | O_NONBLOCK) == 0);
    ext_data_control_source_v1_send_send(current->resource, payloads[i].mime, fds[1]);
    close(fds[1]);
    size_t size = 0;
    unsigned char buffer[65536];
    bool eof = false;
    deadline = now_ms() + 3000;
    while (!eof && now_ms() < deadline) {
      pump(5);
      ssize_t n;
      while ((n = read(fds[0], buffer, sizeof(buffer))) > 0) {
        assert(size + (size_t)n <= payloads[i].size);
        assert(!memcmp(buffer, (const unsigned char *)payloads[i].data + size, (size_t)n));
        size += (size_t)n;
      }
      if (!n)
        eof = true;
    }
    close(fds[0]);
    assert(eof && size == payloads[i].size);
  }
}
static void expect_no_restore(int ms) {
  unsigned before = restores;
  pump(ms);
  assert(!current && restores == before);
}
#define TEXT(m, t) {.mime = m, .data = t, .size = sizeof(t) - 1}
int main(int argc, char **argv) {
  assert(argc == 2);
  signal(SIGPIPE, SIG_IGN);
  display = wl_display_create();
  assert(display);
  loop = wl_display_get_event_loop(display);
  assert(wl_global_create(display, &wl_seat_interface, 1, NULL, bind_seat));
  assert(wl_global_create(display, &ext_data_control_manager_v1_interface, 1, NULL, bind_manager));
  int sockets[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == 0);
  child = fork();
  assert(child >= 0);
  if (!child) {
    close(sockets[0]);
    assert(fcntl(sockets[1], F_SETFD, 0) == 0);
    char fd[32];
    snprintf(fd, sizeof(fd), "%d", sockets[1]);
    setenv("WAYLAND_SOCKET", fd, 1);
    unsetenv("XDG_RUNTIME_DIR");
    execl(argv[1], argv[1], NULL);
    _exit(127);
  }
  close(sockets[1]);
  assert(wl_client_create(display, sockets[0]));
  int64_t deadline = now_ms() + 1500;
  while (!device && now_ms() < deadline)
    pump(10);
  assert(device);
  expect_no_restore(100);

  struct payload rich[] = {TEXT("text/plain;charset=utf-8", "áéí — prueba\n\n"),
                           TEXT("text/html", "<b>prueba</b>\n")};
  external_copy(rich, 2);
  expect_no_restore(150);
  owner_closed();
  expect_restored(rich, 2);
  puts("PASS: live owner untouched; exact UTF-8, newlines and HTML restored; repeated pastes");
  expect_restored(rich, 2);
  unsigned before = restores;
  pump(150);
  assert(restores == before);
  puts("PASS: own clipboard ignored, no feedback loop");

  struct payload lost_event[] = {TEXT("text/plain", "owner died without NULL event")};
  external_copy(lost_event, 1);
  expect_no_restore(150);
  external_active = false; /* Reproduce Hyprland's missing owner-disconnect notification. */
  expect_restored(lost_event, 1);
  puts("PASS: fresh metadata probe detects owner loss even without selection(NULL)");

  struct payload newer[] = {TEXT("text/plain", "newer copy")};
  owner_closed();
  external_copy(newer, 1);
  expect_no_restore(150);
  owner_closed();
  expect_restored(newer, 1);
  puts("PASS: rapid new copy wins over a pending restore");

  struct payload secret[] = {TEXT("text/plain", "test secret"),
                             TEXT("x-kde-passwordManagerHint", "secret")};
  external_copy(secret, 2);
  pump(100);
  owner_closed();
  expect_no_restore(200);
  puts("PASS: sensitive selection discards previous cache and is never restored");

  const unsigned char binary[] = {0x89, 'P', 'N', 'G', 0, 1, 255, 0, 34};
  struct payload image[] = {{.mime = "image/png", .data = binary, .size = sizeof(binary)}};
  external_copy(image, 1);
  pump(100);
  owner_closed();
  expect_restored(image, 1);
  puts("PASS: binary image bytes including NUL preserved");

  struct payload uri[] = {
      TEXT("text/uri-list", "file:///tmp/copy%20test.txt\r\n"),
      TEXT("x-special/gnome-copied-files", "copy\nfile:///tmp/copy%20test.txt")};
  external_copy(uri, 2);
  pump(100);
  owner_closed();
  expect_restored(uri, 2);
  puts("PASS: file copy MIME types preserved");

  struct payload unknown[] = {TEXT("application/x-unsupported", "opaque")};
  external_copy(unknown, 1);
  pump(100);
  owner_closed();
  expect_no_restore(200);
  puts("PASS: unsupported selection cannot resurrect previous content");

  struct payload incomplete[] = {TEXT("text/plain", "complete representation"),
                                 {.mime = "text/html", .stall = true}};
  external_copy(incomplete, 2);
  pump(100);
  owner_closed();
  expect_no_restore(200);
  puts("PASS: owner lost mid-capture cannot restore a partial snapshot");

  struct payload stalled[] = {{.mime = "text/plain", .stall = true}};
  external_copy(stalled, 1);
  pump(2200);
  owner_closed();
  expect_no_restore(200);
  external_copy(newer, 1);
  pump(100);
  owner_closed();
  expect_restored(newer, 1);
  puts("PASS: stalled application times out and subsequent copies still work");

  unsigned char *large = malloc(33u * 1024u * 1024u);
  assert(large);
  memset(large, 'x', 33u * 1024u * 1024u);
  struct payload huge[] = {{.mime = "image/png", .data = large, .size = 33u * 1024u * 1024u}};
  external_copy(huge, 1);
  pump(2500);
  owner_closed();
  expect_no_restore(200);
  puts("PASS: oversized copy dropped with no partial or stale restoration");

  struct payload medium[] = {{.mime = "image/png", .data = large, .size = 512u * 1024u}};
  external_copy(medium, 1);
  pump(300);
  owner_closed();
  expect_restored(medium, 1);
  puts("PASS: image larger than pipe capacity transfers without blocking");

  /* Leave a paste reader stalled, then change the clipboard: event loop stays alive. */
  int blocked[2];
  assert(pipe2(blocked, O_NONBLOCK | O_CLOEXEC) == 0);
  ext_data_control_source_v1_send_send(current->resource, "image/png", blocked[1]);
  close(blocked[1]);
  pump(100);
  external_copy(newer, 1);
  pump(100);
  owner_closed();
  expect_restored(newer, 1);
  close(blocked[0]);
  pump(50);
  puts("PASS: slow paste reader cannot block new copies");

  kill(child, SIGUSR1);
  pump(100);
  expect_no_restore(200);
  external_copy(newer, 1);
  pump(100);
  owner_closed();
  expect_restored(newer, 1);
  puts("PASS: explicit clear discards cache, next copy works");

  kill(child, SIGTERM);
  pump(100);
  int status;
  assert(waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  for (struct transfer *t = transfers; t;) {
    struct transfer *next = t->next;
    if (t->fd >= 0)
      finish_transfer(t);
    free(t);
    t = next;
  }
  free(large);
  wl_display_destroy_clients(display);
  wl_display_destroy(display);
  puts("All protocol integration tests passed.");
  return 0;
}
