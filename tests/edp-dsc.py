#!/usr/bin/env python3
"""Test the DSC policy in a prepared kernel tree with stubbed helpers."""

import argparse
import os
from pathlib import Path
import resource
import shlex
import signal
import subprocess
import tempfile


def extract_function(source):
    start_marker = "static int\nintel_dp_compute_link_for_joined_pipes("
    end_marker = "\nstatic int\nintel_dp_compute_link_config("
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel_source", type=Path,
                        help="kernel source directory after PKGBUILD prepare()")
    args = parser.parse_args()
    source = args.kernel_source / "drivers/gpu/drm/i915/display/intel_dp.c"
    function = extract_function(source.read_text())
    restoration = ("pipe_config->dsc = uncompressed_dsc;\n"
                   "\t\t\tpipe_config->fec_enable = uncompressed_fec_enable;")
    if function.count(restoration) != 1:
        parser.error("expected the patched DSC restoration exactly once")

    fixture = Path(__file__).parent / "fixtures/edp-dsc.c"
    template = fixture.read_text()
    marker = "/* EXTRACTED_FUNCTION */"
    if template.count(marker) != 1:
        raise ValueError("expected one function insertion marker")

    # Keep an expected assertion failure from leaving a core dump behind.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    compiler = shlex.split(os.environ.get("CC", "cc"))
    flags = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-Wno-unused-parameter", "-Wno-unused-variable",
             "-Wno-unused-but-set-variable", "-UNDEBUG"]
    with tempfile.TemporaryDirectory(prefix="edp-dsc-test-") as directory:
        work = Path(directory)

        def build(name, body):
            c_file = work / (name + ".c")
            executable = work / name
            c_file.write_text(template.replace(marker, body))
            subprocess.run(compiler + flags + [str(c_file), "-o", str(executable)],
                           check=True)
            return executable

        patched = build("patched", function)
        subprocess.run([str(patched)], check=True)

        reset_only = function.replace(
            restoration, "intel_dp_dsc_reset_config(pipe_config);")
        mutant = build("reset-only", reset_only)
        result = subprocess.run([str(mutant), "late-dotclock"],
                                capture_output=True, text=True)
        if (result.returncode != -signal.SIGABRT or
                "!s.dsc.compression_enabled_on_link" not in result.stderr):
            raise RuntimeError(
                "reset-only variant did not fail the expected assertion:\n"
                + result.stdout + result.stderr)
        print("PASS: reset-only rollback fails the late-dotclock assertion")


if __name__ == "__main__":
    main()
