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
  modelscope,
  msgpack,
  numpy,
  openai,
  partial-json-parser,
  prompt-toolkit,
  pydantic,
  pyzmq,
  safetensors,
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
    };

  cudaHome = mkCudaHome {
    suffix = "";
    extraPaths = [ ];
  };

  # Kernels JIT-compiled at run time (FreeToken's own and flashinfer's) do reach
  # for the CCCL headers, so the runtime toolkit carries more than the build one.
  cudaRuntimeHome = mkCudaHome {
    suffix = "-runtime";
    extraPaths = [ (lib.getDev cudaPackages.cccl) ];
  };
in
buildPythonPackage (finalAttrs: {
  pname = "freetoken";
  version = "0.1.2";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "FlashML-org";
    repo = "FreeToken";
    tag = "v${finalAttrs.version}";
    hash = "sha256-0MhuubuTjNvtQZxisC2cg1dJeR+A6wZ901H5FRv+l+c=";
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
    modelscope
    msgpack
    numpy
    openai
    partial-json-parser
    prompt-toolkit
    pydantic
    pyzmq
    safetensors
    torch
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

  # Upstream pins are floor=last-verified / ceiling=next-major rather than known
  # incompatibilities; nixpkgs simply carries different releases.
  # - triton:         3.7 in nixpkgs vs. the ==3.6.0 pin
  # - numpy:          2.5 in nixpkgs vs. the <2.5 ceiling (numba's old bound)
  # - gguf:           versioned by llama.cpp build number in nixpkgs, not 0.x
  # - apache-tvm-ffi: same release, but the nixpkgs build derives its own version
  pythonRelaxDeps = [
    "apache-tvm-ffi"
    "gguf"
    "numpy"
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
