#!/bin/bash
# Exercise the carried reload predicate and arrangement cache assignments.
# Only configuration storage is substituted; the tested C++ comes from the patch.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "${1:-$root/pkgbuilds/hyprland/xwayland-scale.patch}" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

patch = Path(sys.argv[1]).read_text()
cpp = patch.split('+++ b/src/state/MonitorLayoutController.cpp\n', 1)[1].split('diff --git ', 1)[0]
added = '\n'.join(line[1:] for line in cpp.splitlines() if line.startswith('+'))
predicate = re.search(r'bool CMonitorLayoutController::xwaylandScaleChanged\(\) const \{.*?\n\}', added, re.S)
assert predicate, 'missing production reload predicate'
assignments = re.findall(r'^\s*m_arranged\w+\s*=.*?;', added, re.M)
header = patch.split('+++ b/src/state/MonitorLayoutController.hpp\n', 1)[1].split('diff --git ', 1)[0]
members = re.findall(r'^\+\s*(mutable\s+[^;]+;)', header, re.M)
assert assignments and members, 'missing production arrangement state'

source = r'''
#include <cstdlib>
#include <iostream>
#include <string>
namespace Config { using FLOAT = float; using INTEGER = long; }
float scale = 0;
long forceZero = 0;
template<class T> struct CConfigValue {
    std::string name;
    explicit CConfigValue(const char* n) : name(n) {}
    T operator*() const { return name == "xwayland:scale" ? T(scale) : T(forceZero); }
};
class CMonitorLayoutController {
public:
    bool xwaylandScaleChanged() const;
    void rememberArrangement() const {
        CConfigValue<Config::FLOAT> PXWLSCALE("xwayland:scale");
        CConfigValue<Config::INTEGER> PXWLFORCESCALEZERO("xwayland:force_zero_scaling");
''' + '\n'.join(assignments) + '\n}\nprivate:\n' + '\n'.join(members) + '\n};\n' + predicate[0] + r'''
void check(bool condition) {
    if (!condition) {
        std::cerr << "FAIL: X11 scale cache did not invalidate or refresh\n";
        std::exit(1);
    }
}
int main() {
    CMonitorLayoutController controller;
    controller.rememberArrangement();
    check(!controller.xwaylandScaleChanged());
    forceZero = 1;
    check(controller.xwaylandScaleChanged());
    controller.rememberArrangement();
    check(!controller.xwaylandScaleChanged());
    forceZero = 0;
    check(controller.xwaylandScaleChanged());
    controller.rememberArrangement();
    check(!controller.xwaylandScaleChanged());
    for (float next : {2.F, -1.F, -2.F, 0.F}) {
        scale = next;
        check(controller.xwaylandScaleChanged());
        controller.rememberArrangement();
        check(!controller.xwaylandScaleChanged());
    }
}
'''
with tempfile.TemporaryDirectory(prefix='xwayland-reload-') as tmp:
    src, exe = Path(tmp) / 'test.cpp', Path(tmp) / 'test'
    src.write_text(source)
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++23', str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: force-zero toggles and explicit/automatic scale changes invalidate the arrangement cache')
PY
