#!/usr/bin/env python3
"""Three changing-input ONNX ReLU jobs, strict DLA admission and DMA cleanup."""
import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile


def compare(actual, expected):
    import numpy as np
    if not np.isfinite(actual).all():
        raise RuntimeError("Non-finite NPU output")
    np.testing.assert_allclose(actual, expected, rtol=0.001, atol=0.001)


def run(prepare_only=False):
    import numpy as np
    from onnx import TensorProto, checker, helper
    from onnx.reference import ReferenceEvaluator
    from n1x_ort import N1xInferenceSession, partition_onnx_model

    shape = [1, 16, 4, 4]
    graph = helper.make_graph([helper.make_node("Relu", ["x"], ["y"], name="relu")],
                              "n1x_npu_relu", [helper.make_tensor_value_info("x", TensorProto.FLOAT, shape)],
                              [helper.make_tensor_value_info("y", TensorProto.FLOAT, shape)])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)], ir_version=8)
    checker.check_model(model)
    with tempfile.TemporaryDirectory(prefix="n1x-npu-qa-") as cache:
        _, stages, _ = partition_onnx_model(model, cache_dir=cache)
        if len(stages) != 1 or stages[0].kind != "DLA":
            raise RuntimeError("ReLU failed to compile into one NPU stage")
        result = {"model_sha256": hashlib.sha256(model.SerializeToString()).hexdigest(),
                  "loadable_sha256": hashlib.sha256(stages[0].nvda_bytes).hexdigest(),
                  "shape": shape, "hardware_verified": False}
        if prepare_only:
            return result
        loader = importlib.machinery.SourceFileLoader("n1x_npu_guard", "/usr/lib/n1x-npu/control")
        spec = importlib.util.spec_from_loader(loader.name, loader)
        guard = importlib.util.module_from_spec(spec)
        loader.exec_module(guard)
        if not guard.admitted():
            raise RuntimeError("N1X ARM64 endpoint/IOMMU admission failed")
        dla = guard.endpoint("NVDA200A")
        guard.verify(dla)
        nodes = [n for n in Path("/sys/class/accel").glob("accel*")
                 if (n / "device").resolve() == dla.resolve()]
        if len(nodes) != 1:
            raise RuntimeError("Expected one NPU accelerator")
        device = str(Path("/dev/accel") / nodes[0].name)
        from n1x_dla import Device
        with Device(device) as fd:
            before = fd.info()
        reference = ReferenceEvaluator(model)
        with N1xInferenceSession(model, cache_dir=cache, device_path=device) as session:
            if session.get_partition_summary()["host_stages"]:
                raise RuntimeError("Unexpected CPU fallback")
            for step in range(3):
                data = np.linspace(-2 + step / 8, 2 + step / 8, 256, dtype=np.float32).reshape(shape)
                compare(session.run(None, {"x": data})[0], reference.run(None, {"x": data})[0])
            summary = session.get_partition_summary()
            if summary["stages"][0]["run_count"] != 3:
                raise RuntimeError("Missing NPU submissions")
        with Device(device) as fd:
            after = fd.info()
        if any(after[k] != before[k] for k in ("retained_bytes", "retained_jobs")):
            raise RuntimeError("NPU DMA allocation remains after closing the inference session")
        result.update(hardware_verified=True, numerical_jobs=3, partition=summary,
                      cleanup_verified=True, retained_before=before, retained_after=after)
        return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true", help="compile only; no NPU or CUDA access")
    args = parser.parse_args()
    print(json.dumps(run(args.prepare_only), indent=2))
