# Cohere Vulkan for Voxtype

A persistent local transcription helper using `transcribe-cpp` 0.2.3. Voxtype 1.0.1's existing Whisper-compatible API client connects to the loopback service; no Voxtype fork is required. Keeping the engines in separate processes avoids linking incompatible copies of ggml with Whisper.

The package contains the helper, source and lockfile in this directory. It does not include model weights. Omarchy's optional dictation installer downloads and verifies the Apache-2.0 Cohere Transcribe 03-2026 Q4_K_M GGUF, probes real Vulkan inference, and manages the user service. Failed checks leave local Whisper available. Only x86_64 is packaged until other architectures have been validated.

## Usage

```sh
voxtype-cohere-vulkan --model /path/to/cohere-transcribe-03-2026-Q4_K_M.gguf --probe
voxtype-cohere-vulkan --model /path/to/cohere-transcribe-03-2026-Q4_K_M.gguf
curl --fail http://127.0.0.1:8178/health
voxtype --engine whisper --whisper-mode remote --remote-endpoint http://127.0.0.1:8178 --remote-model cohere-transcribe-vulkan --language en transcribe recording.wav
```

`--probe` requires an actual Vulkan device and checks transcription of a bundled synthetic English sentence. Software Vulkan renderers and silent CPU fallback are rejected. The normal service warms the model before binding its HTTP socket. `--backend cpu` exists for diagnosis and benchmarks, never automatic fallback.

The API accepts mono 16 kHz PCM16 WAV files, at most 120 seconds / 4 MiB, one inference at a time. It supports Cohere's language codes, defaults to English, and returns JSON text. Long recordings are partitioned at quiet 100 ms windows into segments of at most 35 seconds, with each sample used exactly once. This avoids the missing middle passages observed on unsegmented 60-second recordings. Segmentation may still affect punctuation or words spanning a boundary; it is not diarization or streaming.

The server only binds loopback and does not forward audio. Logs contain timing and device metadata, never audio or transcripts. The probe/benchmark CLI intentionally prints its result. No translation, prompt cleanup or other Whisper API options are implemented.

## Build and validation

Run `makepkg` from this directory. Cargo dependencies are locked. Vulkan and SPIR-V headers are pinned for ggml compatibility; the build disables host-native CPU instructions so artifacts are portable across x86_64 machines. A Vulkan-capable driver is required at runtime, not during packaging.

`cargo test --release --locked` checks silence-boundary selection, the 35-second limit, and exact sample coverage through 10-minute inputs. `--probe` checks model/device compatibility on the destination machine. `--benchmark FILE... --runs 3` repeats inference with a resident model for performance and transcript comparisons.

`test.wav` is a synthetic test fixture saying “The meeting is scheduled for Thursday at three in the afternoon.” It contains no microphone recording or user data.

Runtime source: <https://github.com/handy-computer/transcribe.cpp> (MIT). Model: <https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf> (Apache-2.0), SHA256 `0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb`.
