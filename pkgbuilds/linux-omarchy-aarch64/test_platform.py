#!/usr/bin/env python3
"""Exercise the platform-port helpers from the prepared kernel source."""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile


VIRTUAL_GPIO_TEST = r'''
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <stdio.h>

#define NO_EINT_SUPPORT (-1)
#define EXPORT_SYMBOL_GPL(symbol)
#define PINCTRL_PIN_REG_MODE 1
#define PINCTRL_PIN_REG_DIR 2
#define PINCTRL_PIN_REG_DO 3
#define PINCTRL_PIN_REG_DI 4
#define ENOTSUPP 524
#define GPIO_LINE_DIRECTION_IN 1
#define GPIO_LINE_DIRECTION_OUT 0

struct mtk_pin_func { const char *name; };
struct mtk_pin_desc {
    unsigned int number;
    struct { int eint_m; int eint_n; } eint;
    const struct mtk_pin_func *funcs;
};
struct mtk_pin_soc { const struct mtk_pin_desc *pins; unsigned int npins; unsigned int gpio_m; };
struct mtk_pinctrl { const struct mtk_pin_soc *soc; struct pinctrl_dev *pctrl; };
struct pinctrl_dev { struct mtk_pinctrl *hw; };
struct pinctrl_gpio_range { int unused; };
struct gpio_chip { struct mtk_pinctrl *hw; };
static int writes;
static int last_reg;
static int hw_value = 1;
static struct mtk_pinctrl *pinctrl_dev_get_drvdata(struct pinctrl_dev *pctldev) { return pctldev->hw; }
static struct mtk_pinctrl *gpiochip_get_data(struct gpio_chip *chip) { return chip->hw; }
static int mtk_hw_set_value(struct mtk_pinctrl *hw, const struct mtk_pin_desc *desc, int reg, int value)
{ (void)hw; (void)desc; (void)value; writes++; last_reg = reg; return 0; }
static int mtk_hw_get_value(struct mtk_pinctrl *hw, const struct mtk_pin_desc *desc, int reg, int *value)
{ (void)hw; (void)desc; (void)reg; *value = hw_value; return 0; }
'''

VIRTUAL_GPIO_MAIN = r'''
int main(void)
{
    const struct mtk_pin_func virt_funcs[] = { { .name = NULL }, { .name = "ALT" } };
    const struct mtk_pin_func real_funcs[] = { { .name = "GPIO209" }, { .name = "ALT" } };
    const struct mtk_pin_func no_eint_funcs[] = { { .name = NULL }, { .name = "ALT" } };
    const struct mtk_pin_desc pins[] = {
        { .number = 182, .eint = { .eint_m = 0, .eint_n = 182 },
          .funcs = virt_funcs },
        { .number = 209, .eint = { .eint_m = 0, .eint_n = 209 },
          .funcs = real_funcs },
        { .number = 210, .eint = { .eint_m = NO_EINT_SUPPORT, .eint_n = NO_EINT_SUPPORT },
          .funcs = no_eint_funcs },
    };
    const struct mtk_pin_soc soc = { .pins = pins, .npins = 3, .gpio_m = 0 };
    struct mtk_pinctrl hw = { .soc = &soc };
    struct pinctrl_dev pctldev = { .hw = &hw };
    struct gpio_chip chip = { .hw = &hw };
    hw.pctrl = &pctldev;
    bool (*is_virtual)(struct mtk_pinctrl *, unsigned int) = mtk_is_virt_gpio;

    assert(is_virtual(&hw, 0));
    assert(!is_virtual(&hw, 1));
    assert(!is_virtual(&hw, 2));

    writes = 0;
    assert(mtk_pinmux_gpio_request_enable(&pctldev, NULL, 0) == 0);
    assert(mtk_pinmux_gpio_set_direction(&pctldev, NULL, 0, true) == 0);
    assert(writes == 0);
    assert(mtk_pinmux_gpio_set_direction(&pctldev, NULL, 0, false) == -ENOTSUPP);
    assert(writes == 0);

    assert(mtk_gpio_get_direction(&chip, 0) == GPIO_LINE_DIRECTION_IN);
    assert(mtk_gpio_get(&chip, 0) == -ENOTSUPP);
    assert(mtk_gpio_set(&chip, 0, 1) == -ENOTSUPP);
    assert(mtk_gpio_direction_input(&chip, 0) == 0);
    assert(mtk_gpio_direction_output(&chip, 0, 1) == -ENOTSUPP);
    assert(writes == 0);

    writes = 0;
    assert(mtk_pinmux_gpio_request_enable(&pctldev, NULL, 1) == 0);
    assert(writes == 1 && last_reg == PINCTRL_PIN_REG_MODE);
    assert(mtk_pinmux_gpio_set_direction(&pctldev, NULL, 1, true) == 0);
    assert(writes == 2 && last_reg == PINCTRL_PIN_REG_DIR);
    assert(mtk_gpio_get_direction(&chip, 1) == GPIO_LINE_DIRECTION_OUT);
    assert(mtk_gpio_get(&chip, 1) == 1);
    assert(mtk_gpio_set(&chip, 1, 0) == 0);
    assert(writes == 3 && last_reg == PINCTRL_PIN_REG_DO);
    puts("PASS actual MediaTek virtual GPIO helpers: EINT-only lines are input-only and perform no register writes");
    return 0;
}
'''

IRQ_FALLBACK_TEST = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define ENOTSUPP 524
#define EPROBE_DEFER 517

struct device { int unused; };
struct acpi_device { struct device dev; };
struct spi_device { struct device dev; int irq; };
struct spi_hid_acpi_config { int unused; };
static struct acpi_device companion;
static int gpio_irq_result;
static int gpio_irq_calls;
static struct acpi_device *ACPI_COMPANION(struct device *dev)
{ return dev == NULL ? NULL : &companion; }
static int acpi_dev_gpio_irq_get(struct acpi_device *adev, unsigned int index)
{ assert(adev == &companion && index == 0); gpio_irq_calls++; return gpio_irq_result; }
static int dev_err_probe(struct device *dev, int error, const char *fmt)
{ (void)dev; (void)fmt; return error; }
'''

IRQ_FALLBACK_MAIN = r'''
int main(void)
{
    struct spi_device spi = { .irq = 0 };
    gpio_irq_result = -EPROBE_DEFER;
    assert(obtain_irq(&spi) == -EPROBE_DEFER);
    assert(spi.irq == 0 && gpio_irq_calls == 1);
    gpio_irq_result = 91;
    assert(obtain_irq(&spi) == 91);
    assert(spi.irq == 91 && gpio_irq_calls == 2);
    assert(obtain_irq(&spi) == 91);
    assert(gpio_irq_calls == 2);
    puts("PASS actual SPI ACPI IRQ fallback block: IRQ 0 retries lookup and preserves EPROBE_DEFER");
    return 0;
}
'''


def function_body(text, name):
    match = re.search(rf"(?:static\s+)?(?:int|bool)\s+{name}\s*\([^;]*?\)\s*\{{", text, re.S)
    if not match:
        raise AssertionError(f"function not found: {name}")
    start = match.start()
    opening = text.index("{", match.start())
    depth = 1
    index = opening + 1
    while depth:
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
        index += 1
    return text[start:index]


def compile_and_run(tmp, name, code):
    source = tmp / f"{name}.c"
    binary = tmp / name
    source.write_text(code)
    subprocess.run([
        "cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
        "-Wno-unused-parameter", "-Wno-unused-function", str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel_source", type=Path)
    args = parser.parse_args()
    source = args.kernel_source.resolve()
    paris = (source / "drivers/pinctrl/mediatek/pinctrl-paris.c").read_text()
    common = (source / "drivers/pinctrl/mediatek/pinctrl-mtk-common-v2.c").read_text()
    acpi_spi = (source / "drivers/hid/spi-hid/spi-hid-acpi.c").read_text()

    kconfig = (source / "drivers/platform/wmi/Kconfig").read_text()
    asus_kconfig = (source / "drivers/platform/asus/Kconfig").read_text()
    platform_makefile = (source / "drivers/platform/Makefile").read_text()
    platform_kconfig = (source / "drivers/platform/Kconfig").read_text()
    config = (source / ".config").read_text()
    assert 'menuconfig ACPI_WMI\n\ttristate "ACPI-WMI support"\n\tdepends on ACPI\n' in kconfig
    for symbol in ("ASUS_WMI", "ASUS_NB_WMI"):
        assert f"config {symbol}\n" in asus_kconfig
    assert 'source "drivers/platform/asus/Kconfig"' in platform_kconfig
    assert "obj-$(CONFIG_ASUS_WMI)\t+= asus/" in platform_makefile
    for symbol in ("ACPI_WMI", "ASUS_WMI", "ASUS_NB_WMI", "SPI_HID_ACPI", "SPI_HID_CORE"):
        assert f"CONFIG_{symbol}=m" in config, symbol

    mt8901 = (source / "drivers/pinctrl/mediatek/pinctrl-mtk-mt8901.h").read_text()
    first_pin = mt8901.index('\t\t182, "GPIO182"')
    block_start = mt8901.rfind('\tMTK_PIN(', 0, first_pin)
    block_end = mt8901.index('\n\t),\n};', mt8901.index('\t\t208, "GPIO208"', first_pin)) + len('\n\t),')
    added_gpio_block = mt8901[block_start:block_end]
    pins = [int(value) for value in re.findall(r'\b(18[2-9]|19[0-9]|20[0-8]), "GPIO', added_gpio_block)]
    assert pins == list(range(182, 209)), pins
    for pin in range(182, 209):
        pin_block = re.search(
            rf'MTK_PIN\(\s*{pin}, "GPIO{pin}"(?:(?!\n\t\t\d+, "GPIO).)*?\n\t\),',
            added_gpio_block,
            re.S,
        )
        assert pin_block and f"MTK_EINT_FUNCTION(0, {pin})" in pin_block.group(0), pin
    assert added_gpio_block.count("MTK_FUNCTION(0, NULL)") == 27
    assert "acpi_dev_gpio_irq_get(adev, 0)" in acpi_spi
    assert "return dev_err_probe(dev, error ?: -EINVAL" in acpi_spi

    virt = function_body(common, "mtk_is_virt_gpio")
    functions = "\n\n".join(function_body(paris, name) for name in (
        "mtk_pinmux_gpio_request_enable", "mtk_pinmux_gpio_set_direction",
        "mtk_gpio_get_direction", "mtk_gpio_get", "mtk_gpio_set",
        "mtk_gpio_direction_input", "mtk_gpio_direction_output",
    ))
    start = acpi_spi.index("\t/* Retry GPIO IRQ lookup at probe when SPI enumeration has no IRQ. */")
    end = acpi_spi.index("\n\n\tconfig =", start)
    irq_block = acpi_spi[start:end]

    with tempfile.TemporaryDirectory(prefix="p16-platform-test-") as directory:
        tmp = Path(directory)
        compile_and_run(tmp, "virtual_gpio", VIRTUAL_GPIO_TEST + virt + functions + VIRTUAL_GPIO_MAIN)
        spi_function = (
            "static int obtain_irq(struct spi_device *spi)\n{\n"
            "    struct device *dev = &spi->dev;\n"
            "    struct acpi_device *adev = ACPI_COMPANION(dev);\n"
            "    int error;\n"
            "    if (!adev) return -ENODEV;\n"
            + irq_block + "\n"
            "    return spi->irq;\n"
            "}\n"
        )
        compile_and_run(tmp, "spi_irq", IRQ_FALLBACK_TEST + spi_function + IRQ_FALLBACK_MAIN)
    print("PASS ARM64 platform Kconfig/Makefile, GPIO 182-208 table, real virtual GPIO helpers, and SPI IRQ error fallback")


if __name__ == "__main__":
    main()
