"""Load executable Python helpers without installing them."""
import importlib.machinery
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_script(relative):
    path = ROOT / relative
    loader = importlib.machinery.SourceFileLoader(path.name.replace('-', '_'), str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module
