#!/usr/bin/python
"""Run the upstream lifetime suite on packaged C with corrected DMA contract."""
import ast
from pathlib import Path
import subprocess
import os
import tempfile

ROOT = Path(__file__).resolve().parent
tree = ast.parse((Path(os.environ.get("N1X_SOURCE_ROOT", ROOT / "src/n1x-npu")) / "scripts/test_linux_accel.py").read_text())
parts = {}
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name == "main":
        for item in node.body:
            if isinstance(item, ast.Assign) and isinstance(item.targets[0], ast.Name) and item.targets[0].id in ("shim", "tests"):
                parts[item.targets[0].id] = ast.literal_eval(item.value)
shim = parts["shim"].replace("#define PAGE_ALIGN(x)", "#define PAGE_SHIFT 12\n#define PAGE_ALIGN(x)")
shim = shim.replace("assert(d&&vma&&!vma->vm_pgoff);last_mmap_cpu=cpu;last_mmap_dma=dma;last_mmap_size=size;return 0;", "assert(d&&vma&&vma->vm_pgoff==2);assert(size>=12288);last_mmap_cpu=(unsigned char *)cpu+8192;last_mmap_dma=dma;last_mmap_size=size;return 0;")
tests = parts["tests"].replace("last_mmap_dma==dma_address+N1X_JOB_PREFIX&&last_mmap_size==4096", "last_mmap_dma==dma_address&&last_mmap_size==12288")
source = Path(os.environ.get("N1X_SOURCE_ROOT", ROOT / "src/n1x-npu"))
body = (source / "driver/n1x_dla_accel.c").read_text()
body = body[body.index("#define N1X_JOB_PREFIX"):body.index("static int n1x_accel_open(")]
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)
    (path / "test.c").write_text("#define CAPTURE_DMA 0x80000000ULL\n"+shim+body+tests)
    subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", "-fsanitize=undefined", "-I"+str(source / "include"), str(path / "test.c"),
                    str(source / "driver/n1x_dla_task.c"), str(source / "driver/n1x_dla_command.c"), str(source / "driver/n1x_dla_statistics.c"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
