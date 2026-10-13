"""Exercise decoration lifetime using the method from the prepared Hyprland source."""
import argparse
import os
import shlex
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path, help='prepared src/desktop/view/Window.cpp')
args = parser.parse_args()
fixture = r'''
#include <algorithm>
#include <array>
#include <memory>
#include <span>
#include <vector>
#include <iostream>
struct CWindow;
struct Decoration {
    bool* listener;
    int* updates;
    ~Decoration() { *listener = false; }
    void updateWindow(CWindow*) { ++*updates; }
};
using IHyprWindowDecoration = Decoration;
struct Positioner {
    int uncached = 0;
    int updates = 0;
    void uncacheDecoration(Decoration*) { ++uncached; }
    void onWindowUpdate(CWindow*) { ++updates; }
} positioner;
auto g_pDecorationPositioner = &positioner;
struct CWindow {
    bool m_isMapped = true;
    bool hidden = false;
    struct Self { CWindow* ptr; CWindow* lock() const { return ptr; } } m_self{this};
    std::vector<Decoration*> m_decosToRemove;
    std::vector<std::unique_ptr<Decoration>> m_windowDecorations;
    bool isHidden() const { return hidden; }
    void updateWindowDecos();
};
METHOD
int main() {
    for (int state = 0; state < 3; ++state) {
        positioner = {};
        bool listener = true, survivingListener = true;
        int removedUpdates = 0, survivingUpdates = 0;
        CWindow w;
        w.hidden = state == 1;
        w.m_isMapped = state != 2;
        w.m_windowDecorations.emplace_back(new Decoration{&listener, &removedUpdates});
        w.m_windowDecorations.emplace_back(new Decoration{&survivingListener, &survivingUpdates});
        w.m_decosToRemove.push_back(w.m_windowDecorations[0].get());
        w.updateWindowDecos();
        if (listener || !w.m_decosToRemove.empty() || w.m_windowDecorations.size() != 1 || positioner.uncached != 1) {
            std::cerr << "FAIL: callback/decoration survives removal, state=" << state << "\n";
            return 1;
        }
        if (survivingUpdates != (state == 0 ? 1 : 0) || removedUpdates != 0 || !survivingListener) {
            std::cerr << "FAIL: unrelated decoration update behavior changed\n";
            return 1;
        }
        w.updateWindowDecos();
        if (positioner.uncached != 1) return 1;
    }
    std::cout << "PASS: visible, hidden, unmapped lifetime cleanup; no double removal\n";
}
'''
source = args.source.read_text()
method = source[source.index('void CWindow::updateWindowDecos()'):source.index('void CWindow::addWindowDeco(')]
with tempfile.TemporaryDirectory(prefix='hypr-cleanup-test-') as directory:
    temp = Path(directory)
    cpp = temp / 'cleanup.cpp'
    cpp.write_text(fixture.replace('METHOD', method))
    binary = temp / 'cleanup'
    compiler = shlex.split(os.environ.get('CXX', 'c++'))
    subprocess.run([*compiler, '-std=c++23', '-O0', '-Wall', '-Wextra', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
