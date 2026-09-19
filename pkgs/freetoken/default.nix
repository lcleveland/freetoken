{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  symlinkJoin,

  # build-system
  setuptools,
  wheel,
  torch,

  # native build inputs
  ninja,
  # Keep the CUDA toolkit in lockstep with the one torch was built against:
  # freetoken's setup.py refuses to nvcc-compile across CUDA majors, and the
  # extensions link libcudart from this toolkit.
  cudaPackages ? torch.cudaPackages,

  # dependencies
  apache-tvm-ffi,
  einops,
  fastapi,
  flashlib,
  gguf,
  huggingface-hub,
  msgpack,
  numpy,
  openai,
  partial-json-parser,
  pillow,
  prompt-toolkit,
  pydantic,
  pyzmq,
  safetensors,
  torchvision,
  tqdm,
  transformers,
  triton,
  uvicorn,

  # optional-dependencies
  flashinfer-python,

  # tests
  versionCheckHook,
}:

let
  # setup.py wants a single CUDA_HOME holding bin/nvcc, include/ and a lib dir
  # with libcudart; nixpkgs splits those across packages and outputs, so join
  # them. The extensions are plain C++ (`cuda_runtime_api.h` and `-lcudart`),
  # so the build needs nothing else.
  #
  # `lib64` is not a stray alias. A real CUDA install keeps its 64-bit libraries
  # there, and both setup.py and tvm-ffi link against that spelling
  # specifically -- tvm-ffi hardcodes `-L$CUDA_HOME/lib64 -lcudart` for every
  # JIT module it builds. nixpkgs only ever produces `lib`, so without the alias
  # the runtime JIT link fails with `cannot find -lcudart`.
  mkCudaHome =
    { suffix, extraPaths }:
    symlinkJoin {
      name = "freetoken-cuda-home${suffix}-${cudaPackages.cudaMajorMinorVersion}";
      paths =
        with cudaPackages;
        [
          (lib.getBin cuda_nvcc)
          (lib.getDev cuda_nvcc)
          (lib.getDev cuda_cudart)
          (lib.getLib cuda_cudart)
        ]
        ++ extraPaths;
      postBuild = ''
        [ -e "$out/lib64" ] || ln -s lib "$out/lib64"
      '';
    };

  cudaHome = mkCudaHome {
    suffix = "";
    extraPaths = [ ];
  };

  # Kernels JIT-compiled at run time reach well past what the build needs, so
  # the runtime toolkit is the larger of the two. FreeToken's own kernels want
  # the CCCL headers; flashinfer's want cuBLAS and cuRAND on top of that, and
  # resolve every one of them through `$CUDA_HOME/include` and
  # `$CUDA_HOME/lib64` (`flashinfer.jit.cpp_ext`) rather than through anything a
  # Nix setup hook could supply. The list mirrors flashinfer's own
  # `buildInputs` in nixpkgs, which is the source of truth for what its kernels
  # include; omitting cuBLAS fails at the first attention kernel with
  # `cublasLt.h: No such file or directory`.
  cudaRuntimeHome = mkCudaHome {
    suffix = "-runtime";
    #
    # Note the output names: the CUDA redistributables split their headers into
    # a dedicated `include` output, so `lib.getDev` on one of them yields only
    # setup hooks and no `include/` at all -- the join comes out with the
    # libraries present and the headers still missing.
    extraPaths = with cudaPackages; [
      (lib.getDev cccl)
      (lib.getOutput "include" libcublas)
      (lib.getLib libcublas)
      (lib.getOutput "include" libcurand)
      (lib.getLib libcurand)
    ];
  };
in
buildPythonPackage (finalAttrs: {
  pname = "freetoken";

  version = "0.1.3";

  pyproject = true;

  src = fetchFromGitHub {
    owner = "FlashML-org";
    repo = "FreeToken";
    tag = "v${finalAttrs.version}";
    hash = "sha256-59itjnwDr4P7I/ZLIbkNw9/8CCPvTP7yNWl9ogBnZ3o=";
  };

  build-system = [
    setuptools
    torch
    wheel
  ];

  nativeBuildInputs = [
    ninja
    (lib.getBin cudaPackages.cuda_nvcc)
  ];

  buildInputs = [
    (lib.getLib cudaPackages.cuda_cudart)
  ];

  # The torch pin also sits in [build-system].requires, where pythonRelaxDeps
  # cannot reach it: `pypa build --no-isolation` resolves that list against the
  # build environment and rejects nixpkgs' newer torch before setup.py even runs.
  # One substitution covers both that entry and the runtime one.
  postPatch = ''
    substituteInPlace pyproject.toml \
      --replace-fail '"torch>=2.11,<2.12"' '"torch"'
  '';

  env.CUDA_HOME = cudaHome;

  dependencies = [
    apache-tvm-ffi
    einops
    fastapi
    flashlib
    gguf
    huggingface-hub
    msgpack
    numpy
    openai
    partial-json-parser
    pillow
    prompt-toolkit
    pydantic
    pyzmq
    safetensors
    torch
    torchvision
    tqdm
    transformers
    triton
    uvicorn
  ];

  optional-dependencies = {
    # Native fused attention kernels. Without them the runtime falls back to the
    # pure-Triton kernels in freetoken.kernel.triton.
    fi = [ flashinfer-python ];
    # Upstream's `accel` extra is fi + sglang-kernel; sglang-kernel is an
    # ABI-locked binary wheel with no nixpkgs package, so `accel` is `fi` here.
    accel = [ flashinfer-python ];
  };

  # modelscope is upstream's alternative model-download backend: `snapshot_download`
  # is imported lazily in server/args.py, and only when `--model-source modelscope`
  # is given a model path that is not already a local directory. nixpkgs marks the
  # package insecure (CVE-2026-84202, unsafe YAML deserialisation while loading a
  # model config), which refuses evaluation of every system that pulls freetoken in.
  # Hugging Face is the default and the only source this flake's module exposes, so
  # drop the dep instead of permitting the CVE; `--model-source modelscope` then
  # fails with an ImportError rather than silently reaching for a vulnerable loader.
  pythonRemoveDeps = [ "modelscope" ];

  # Upstream pins are floor=last-verified / ceiling=next-major rather than known
  # incompatibilities; nixpkgs simply carries different releases.
  # - triton:         3.7 in nixpkgs vs. the ==3.6.0 pin
  # - numpy:          2.5 in nixpkgs vs. the <2.5 ceiling (numba's old bound)
  # - gguf:           versioned by llama.cpp build number in nixpkgs, not 0.x
  # - apache-tvm-ffi: same release, but the nixpkgs build derives its own version
  # - transformers:   5.17 in nixpkgs vs. the <5.17 ceiling
  # - torchvision:    0.28 in nixpkgs vs. the <0.27 ceiling
  pythonRelaxDeps = [
    "apache-tvm-ffi"
    "gguf"
    "numpy"
    "torchvision"
    "transformers"
    "triton"
  ];

  # The test suite is not run: every test needs an NVIDIA GPU and most need a
  # real checkpoint, so no pytest hook is wired up here.

  pythonImportsCheck = [
    "freetoken"
    "freetoken.cli"
  ];

  # `ft --version` is deliberately torch-free upstream, so it runs in the sandbox.
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  passthru = {
    inherit cudaHome cudaRuntimeHome cudaPackages;
  };

  meta = {
    description = "Edge-native MoE serving engine for frontier open-weight models";
    longDescription = ''
      FreeToken is a Mixture-of-Experts serving engine for running frontier-scale
      open-weight models on consumer NVIDIA hardware, with bandwidth-adaptive
      CPU-GPU co-execution, expert offloading and OpenAI- and
      Anthropic-compatible HTTP APIs.
    '';
    homepage = "https://github.com/FlashML-org/FreeToken";
    changelog = "https://github.com/FlashML-org/FreeToken/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    mainProgram = "ft";
    platforms = [ "x86_64-linux" ];
  };
})
