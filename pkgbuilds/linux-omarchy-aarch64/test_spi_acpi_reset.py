"""Compile the production ACPI reset callback; the ACPI object's dev has no companion."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel_source', type=Path)
    args = parser.parse_args()
    text = (args.kernel_source / 'drivers/hid/spi-hid/spi-hid-acpi.c').read_text()
    match = re.search(r'static int spi_hid_acpi_deassert_reset\([^)]*\)\n\{.*?\n\}', text, re.S)
    if not match:
        raise ValueError('production reset callback missing')
    code = r'''
#include <assert.h>
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <stdbool.h>
#define container_of(ptr, type, member) ((type *)((char *)(ptr) - offsetof(type, member)))
#define ACPI_FAILURE(status) ((status) != 0)
#define acpi_handle_err(handle, ...) ((void)(handle), errors++)
typedef int acpi_status;
struct device { void *companion; };
struct acpi_device { struct device dev; void *handle; };
struct spihid_ops { int unused; };
struct spi_hid_acpi_config { struct spihid_ops ops; struct acpi_device *adev; };
static int calls, errors, firmware_status;
static void *expected_handle;
static int device_reset(struct device *dev) { (void)dev; return -ENOENT; }
static acpi_status acpi_evaluate_object(void *handle, const char *method, void *args, void *output)
{
    assert(handle == expected_handle);
    assert(strcmp(method, "_RST") == 0);
    assert(!args && !output);
    calls++;
    return firmware_status;
}
''' + match[0] + r'''
int main(void)
{
    int handle;
    struct acpi_device adev = { .dev = { .companion = NULL }, .handle = &handle };
    struct spi_hid_acpi_config conf = { .adev = &adev };
    expected_handle = &handle;
    assert(spi_hid_acpi_deassert_reset(&conf.ops) == 0);
    assert(calls == 1 && errors == 0);
    firmware_status = 1;
    assert(spi_hid_acpi_deassert_reset(&conf.ops) == -EIO);
    assert(calls == 2 && errors == 1);
    return 0;
}
'''
    with tempfile.TemporaryDirectory(prefix='p16-reset-test-') as directory:
        path = Path(directory)
        (path / 'test.c').write_text(code)
        subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        '-Wno-unused-function', str(path/'test.c'), '-o', str(path/'test')], check=True)
        subprocess.run([str(path/'test')], check=True)
    print('PASS production SPI-HID reset uses its ACPI handle and reports firmware errors')


if __name__ == '__main__':
    main()
