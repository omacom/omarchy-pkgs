obj-m += gb10-cx7-hotplug.o
gb10-cx7-hotplug-y := mtk-pcie-hotplug.o

KDIR ?= /usr/lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
