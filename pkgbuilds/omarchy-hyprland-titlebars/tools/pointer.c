#include <wayland-client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "pointer-protocol.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
  if (!strcmp(interface, "zwlr_virtual_pointer_manager_v1"))
    manager = wl_registry_bind(registry, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void removed(void *data, struct wl_registry *registry, uint32_t name) {}

int main(int argc, char **argv) {
  if (argc != 3)
    return 2;
  struct wl_display *display = wl_display_connect(NULL);
  if (!display)
    return 1;
  struct wl_registry *registry = wl_display_get_registry(display);
  const struct wl_registry_listener listener = {global, removed};
  wl_registry_add_listener(registry, &listener, NULL);
  wl_display_roundtrip(display);
  if (!manager)
    return 3;
  struct zwlr_virtual_pointer_v1 *pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
  char line[128], command[32];
  int x, y;
  while (fgets(line, sizeof(line), stdin)) {
    if (sscanf(line, "%31s %d %d", command, &x, &y) < 1)
      continue;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint32_t now = ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
    if (!strcmp(command, "move"))
      zwlr_virtual_pointer_v1_motion_absolute(pointer, now, x, y, atoi(argv[1]), atoi(argv[2]));
    else if (!strcmp(command, "down"))
      zwlr_virtual_pointer_v1_button(pointer, now, 272, WL_POINTER_BUTTON_STATE_PRESSED);
    else if (!strcmp(command, "up"))
      zwlr_virtual_pointer_v1_button(pointer, now, 272, WL_POINTER_BUTTON_STATE_RELEASED);
    else if (!strcmp(command, "wait"))
      usleep(x * 1000);
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_roundtrip(display);
  }
  zwlr_virtual_pointer_v1_destroy(pointer);
  zwlr_virtual_pointer_manager_v1_destroy(manager);
  wl_registry_destroy(registry);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
