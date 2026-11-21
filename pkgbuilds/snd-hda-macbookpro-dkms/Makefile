KBUILD_EXTRA_CFLAGS := -DAPPLE_PINSENSE_FIXUP -DAPPLE_CODECS \
	-DCONFIG_SND_HDA_RECONFIG=1 -Wno-unused-variable -Wno-unused-function

ifndef KERNELRELEASE
$(error KERNELRELEASE must name the target kernel)
endif

KERNELBUILD := /usr/lib/modules/$(KERNELRELEASE)/build
MODULE_ROOT := $(CURDIR)/build/hda

.PHONY: all clean

all:
	$(MAKE) -C $(KERNELBUILD) CFLAGS_MODULE="$(KBUILD_EXTRA_CFLAGS)" \
		M=$(MODULE_ROOT) modules

clean:
	$(MAKE) -C $(KERNELBUILD) M=$(MODULE_ROOT) clean
