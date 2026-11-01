#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise the actual read-only activation helper and CONFIG declarations."""
from pathlib import Path
import os
import sys
import subprocess
import tempfile

root = Path(sys.argv[1]).resolve()
source = (root / 'drivers/acpi/processor_idle.c').read_text()
start = source.index('bool acpi_processor_n1x_s2idle_active(void)')
end = source.index('\n}', start) + 2
function = source[start:end]
header = (root / 'include/acpi/processor.h').read_text()
a = header.index('#if IS_BUILTIN(CONFIG_ACPI_PROCESSOR) && defined(CONFIG_ACPI_PROCESSOR_IDLE)')
b = header.index('\n#endif', a) + len('\n#endif')
declaration = header[a:b]
prelude = '''#include <assert.h>
#include <stdbool.h>
#define READ_ONCE(x) (x)
#define ACPI_LPI_COORDINATED 3
static bool n1x_coordinated_gate_allowed, acpi_lpi_system_sleep;
static int acpi_lpi_lifecycle;
'''
main = '''
int main(void) {
 for (int gate = 0; gate < 2; ++gate)
  for (int state = 0; state < 4; ++state)
   for (int sleep = 0; sleep < 2; ++sleep) {
    n1x_coordinated_gate_allowed = gate;
    acpi_lpi_lifecycle = state;
    acpi_lpi_system_sleep = sleep;
    assert(acpi_processor_n1x_s2idle_active() ==
           (gate && state == ACPI_LPI_COORDINATED && sleep));
   }
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='n1x-gate-test-') as tmp:
    tmp = Path(tmp)
    units = [('actual', prelude + function + main)]
    for processor in (0, 1, 2):
        for idle in (False, True):
            text = '#include <stdbool.h>\n#define IS_BUILTIN(x) ((x) == 1)\n'
            text += f'#define CONFIG_ACPI_PROCESSOR {processor}\n'
            if idle:
                text += '#define CONFIG_ACPI_PROCESSOR_IDLE 1\n'
            text += declaration
            if processor == 1 and idle:
                text += '\nbool acpi_processor_n1x_s2idle_active(void) { return true; }\n'
                text += 'int main(void) { return !acpi_processor_n1x_s2idle_active(); }\n'
            else:
                text += '\nint main(void) { return acpi_processor_n1x_s2idle_active(); }\n'
            units.append((f'config-{processor}-{idle}', text))
    for name, text in units:
        cfile = tmp / f'{name}.c'
        cfile.write_text(text)
        binary = tmp / name
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
                        '-Werror', str(cfile), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
print('actual gate: 16 lifecycle cases and six CONFIG variants passed')
