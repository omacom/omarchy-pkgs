# Build the J313 keyboard-backlight daemon. Does not install it.
CC ?= gcc
CFLAGS ?= -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror
LDFLAGS ?= -lm

.PHONY: all self-test clean

all: ct720-kbd-light

ct720-kbd-light: ct720-kbd-light.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

self-test: ct720-kbd-light
	./ct720-kbd-light --self-test

clean:
	rm -f ct720-kbd-light
