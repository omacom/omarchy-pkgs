# Build the J313 panel-brightness daemon. Does not install it.
CC ?= gcc
CFLAGS ?= -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror
LDFLAGS ?= -lm

.PHONY: all self-test clean

all: ct720-display-light

ct720-display-light: ct720-display-light.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

self-test: ct720-display-light
	./ct720-display-light --self-test

clean:
	rm -f ct720-display-light
