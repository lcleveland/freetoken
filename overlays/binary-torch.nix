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
  # ponytail: pinned to 13.3 because nixpkgs' cudaPackages_13 moved to 13.4 before
  # its cuda-bindings did ("Unsupported cuda-bindings version: 13.4"). Go back to
  # cudaPackages_13 once pkgs/development/python-modules/cuda-bindings has 13_4.nix.
  cudaPackages = final.cudaPackages_13_3.overrideScope (
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
          #
          # ponytail: wheels pinned here ahead of nixpkgs, which still ships 2.13 /
          # 3.7 / 0.28 and only has cp314 x86_64 hashes. Drop the version/src
          # overrides once nixpkgs' torch-bin reaches 2.14.
          #
          # Overridden under the -bin names because torchvision-bin takes
          # `torch-bin` by name; the plain names point at these below.
          torch-bin = pyPrev.torch-bin.overrideAttrs (old: {
            version = "2.14.1";
            src = final.fetchurl {
              name = "torch-2.14.1+cu130-cp314-cp314-linux_x86_64.whl";
              url = "https://download.pytorch.org/whl/cu130/torch-2.14.1%2Bcu130-cp314-cp314-manylinux_2_28_x86_64.whl";
              hash = "sha256-Ugb6gxY6px3AGGY3sqouw/txFIkgOf3ePJG/VwvSO6g=";
            };
            passthru = (old.passthru or { }) // {
              cudaSupport = true;
              rocmSupport = false;
              cudaPackages = final.cudaPackages;
              cudaCapabilities = final.cudaPackages.flags.cudaCapabilities;
            };
          });

          triton-bin = pyPrev.triton-bin.overridePythonAttrs (old: {
            version = "3.8.0";
            # nixpkgs' libcuda patch targets 3.7, where it returns one path; in
            # 3.8 it lands in `libcuda_dirs()`, which must return a list of dirs.
            postFixup = old.postFixup + ''
              substituteInPlace "$out/${final.python3.sitePackages}/triton/backends/nvidia/driver.py" \
                --replace-fail \
                  "return '${final.addDriverRunpath.driverLink}/lib/libcuda.so'" \
                  "return ['${final.addDriverRunpath.driverLink}/lib']"
            '';
            src = final.fetchurl {
              name = "triton-3.8.0-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
              url = "https://download.pytorch.org/whl/triton-3.8.0-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl";
              hash = "sha256-SJ7+VmQeG8XT3zyfO6m8x7uN7kBpGuiMz1STiHN5UaI=";
            };
          });

          # torchvision builds against `torch.cxxdev`, which only the
          # from-source torch has; its own wheel matches torch-bin's ABI.
          torchvision-bin = pyPrev.torchvision-bin.overrideAttrs {
            version = "0.29.1";
            src = final.fetchurl {
              name = "torchvision-0.29.1+cu130-cp314-cp314-linux_x86_64.whl";
              url = "https://download.pytorch.org/whl/cu130/torchvision-0.29.1%2Bcu130-cp314-cp314-manylinux_2_28_x86_64.whl";
              hash = "sha256-pb2tZnAFwU5ELd95M8BI4CGDSvr0jmS5IMrra9HNfRU=";
            };
          };

          torch = pyFinal.torch-bin;
          triton = pyFinal.triton-bin;
          torchvision = pyFinal.torchvision-bin;

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
