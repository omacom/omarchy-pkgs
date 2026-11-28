# N1X native runtime and ONNX inference tools

Source pin: n1x-npu-linux 92e9434a65d2b9d3bb0517efb9efc371e9c6b42c.
CI compiles libn1x_dla, libn1x_compiler and libn1x_ort plus CLI programs from
source. Python uses distribution numpy/onnx; no prebuilt venv, pip installation,
NVIDIA binary or generated model is packaged. Nothing starts hardware on install.

The ONNX backend uses the native DLA ioctl path. Its model parser's upstream
public fallback tensor declaration allows building without proprietary cuDLA
headers. The optional cuDLA frontend/backend is not included: numerical ONNX
inference uses libn1x_ort directly and does not require CUDA/GPU initialization.

Native t254 graph compilation additionally needs the exact local TensorRT 11.4
Linux libnvdla_compiler.so and Windows ARM64 nvdla_compiler.dll. These remain
separate administrator-supplied files under their applicable licenses. No
redistribution permission is asserted. The compiler shim maps/patches the pinned
vendor binaries in-process; distribution/use terms and this technique need
maintainer review before considering a redistributable vendor integration.

Acquire under the applicable NVIDIA terms following upstream docs/setup.md,
then explicitly verify/stage to a temporary directory:

    n1x-npu-prepare-compiler --linux-so /local/libnvdla_compiler.so \
      --windows-dll /local/nvdla_compiler.dll --output-dir ./compiler-inputs

Review output, then explicitly install those files root-owned under
/usr/local/lib/n1x-npu/. Python verifies both full SHA256 hashes before mapping
code. Missing/wrong files fail closed. package() never touches /usr/local.
No downloader, restart, firmware activation or module loading is performed.

After the separately opted-in n1x-npu.service succeeds:

    n1x-npu-infer --prepare-only
    sudo n1x-npu-infer

The first command compiles only (no NPU or GPU access); the second requires
ARM64 N1X sysfs/IOMMU/provider verification, runs exactly three changing-input
ReLU ONNX jobs, compares independent ONNX reference outputs, rejects CPU fallback
and verifies session-close retained-allocation cleanup. The administrator must
prepare local firmware/provider and the missing-_CCA kernel quirk separately.
The expected loadable SHA256 is
9c7d3dd9d7c949a20b95f6e0203c74a47711415b5a7b423791e42e12965706e7.

Source with the provider mmap fix passed three real numerical jobs plus cleanup
before and after a 78.482-second s2idle cycle on one ASUS P16/N1X. This package
build uses the source tensor fallback instead of vendor cuDLA headers, and public
local-input packaging requires its own first-boot QA. CI tests compile/parse and
exercise CPU-side runtime interfaces; they do not claim NPU hardware coverage.

Keep draft for provider/kernel dependencies and maintainer review of the compiler
shim and applicable vendor terms. sync=false holds the reviewed source pin;
rebuild_on tracks Python/native Python dependency changes. This source project's
MIT license does not relicense vendor inputs. See packaged upstream NOTICE and
LICENSING.md plus NVIDIA's applicable TensorRT and SDK terms.
