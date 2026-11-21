CC ?= cc
CFLAGS ?= -O2 -g
WARNINGS = -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter
PROTO = $(shell pkg-config --variable=pkgdatadir wayland-protocols)/staging/ext-data-control/ext-data-control-v1.xml
BUILD ?= build

all: $(BUILD)/omarchy-clipboard-keeper

$(BUILD):
	mkdir -p $@

$(BUILD)/control-client.h: $(PROTO) | $(BUILD)
	wayland-scanner client-header $< $@

$(BUILD)/control-server.h: $(PROTO) | $(BUILD)
	wayland-scanner server-header $< $@

$(BUILD)/control.c: $(PROTO) | $(BUILD)
	wayland-scanner private-code $< $@

$(BUILD)/omarchy-clipboard-keeper: keeper.c $(BUILD)/control-client.h $(BUILD)/control.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -I$(BUILD) keeper.c $(BUILD)/control.c $(LDFLAGS) -o $@ $$(pkg-config --cflags --libs wayland-client)

$(BUILD)/test-keeper: test-keeper.c $(BUILD)/control-server.h $(BUILD)/control.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARNINGS) -UNDEBUG -I$(BUILD) test-keeper.c $(BUILD)/control.c $(LDFLAGS) -o $@ $$(pkg-config --cflags --libs wayland-server)

check: all $(BUILD)/test-keeper
	$(BUILD)/test-keeper $(abspath $(BUILD)/omarchy-clipboard-keeper)

.PHONY: all check
