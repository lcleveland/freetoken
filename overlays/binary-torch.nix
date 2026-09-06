# Build FreeToken against PyTorch's own wheel instead of nixpkgs' from-source
# torch.
#
# nixpkgs builds torch with `cudaSupport` from source, and hydra cannot cache
# it, so a plain `services.freetoken.enable = true` would mean hours of
# compiling before the first token. `torch-bin` is upstream's cu130 wheel:
# a download plus autoPatchelf. FreeToken's own C++ extensions still compile
# here, but that is two small translation units.
#
# CUDA 13 comes with it, not as a preference: the wheel is the cu130 build,
# nixpkgs' torch-bin refuses to evaluate against a cuda-bindings older than
# 13.0.3, and FreeToken's setup.py refuses to build kernels with an nvcc whose
# major does not match torch's.
final: prev: {
  # NCCL and NVSHMEM come from NVIDIA's own wheels rather than nixpkgs' source
  # builds: both are hard buildInputs of torch-bin, neither is in any binary
  # cache, and building NCCL means compiling its device kernels for every entry
  # in `cudaCapabilities` -- for collectives a single-GPU engine never calls.
  cudaPackages = final.cudaPackages_13.overrideScope (
    cudaFinal: _cudaPrev: final.callPackage ../pkgs/nvidia-wheels { cudaPackages = cudaFinal; }
  );

  python3 =
    let
      python = prev.python3.override {
        # Without `self` the overrides below apply only to the top of the
        # package set: everything that resolves `torch` through the set --
        # flashlib, flashinfer, freetoken itself -- would still get the
        # from-source build.
        self = python;

        packageOverrides = pyFinal: pyPrev: {
          # The wheel carries none of the passthru that nixpkgs' from-source
          # torch exposes, and CUDA consumers read it: flashinfer-python gates
          # on `torch.cudaSupport` and builds its arch list from
          # `torch.cudaCapabilities`. The wheel is a CUDA build by
          # construction, so state that rather than let it look CPU-only.
          torch = pyPrev.torch-bin.overrideAttrs (old: {
            passthru = (old.passthru or { }) // {
              cudaSupport = true;
              rocmSupport = false;
              cudaPackages = final.cudaPackages;
              cudaCapabilities = final.cudaPackages.flags.cudaCapabilities;
            };
          });

          triton = pyPrev.triton-bin;

          # AOT mode compiles every kernel ahead of time, which is the second
          # multi-hour build in this closure. JIT mode installs in seconds and
          # compiles what it actually needs on first use, with the toolkit the
          # `ft` wrapper already puts on PATH for exactly that reason.
          flashinfer-python = pyPrev.flashinfer-python.overrideAttrs (_: {
            preConfigure = ''
              export MAX_JOBS="$NIX_BUILD_CORES"
            '';
          });
        };
      };
    in
    python;

  python3Packages = final.python3.pkgs;
}
