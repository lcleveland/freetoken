{
  lib,
  config,
  stdenvNoCC,
  # Swapping the interpreter also swaps the package set the runtime is built
  # from: `freetoken.override { python3 = pkgs.python313; }`.
  python3,
  makeWrapper,
  symlinkJoin,
  addDriverRunpath,
  gcc,
  binutils,

  # Pull in flashinfer's fused kernels. Turning this off leaves the runtime on
  # its pure-Triton fallbacks (`--attention-backend triton`), which is a much
  # smaller build. flashinfer is marked broken without `cudaSupport`, so on a
  # CPU-only nixpkgs this defaults off and you get a CLI that builds but cannot
  # serve — set `nixpkgs.config.cudaSupport` (or use this flake's packages).
  withAccel ? config.cudaSupport,

  # Extra python packages to expose to the runtime, e.g. `ps: [ ps.pynvml ]`.
  extraPythonPackages ? (_ps: [ ]),
}:

let
  inherit (python3.pkgs) freetoken;

  pythonEnv = python3.withPackages (
    ps:
    [ ps.freetoken ]
    ++ lib.optionals withAccel ps.freetoken.optional-dependencies.accel
    ++ extraPythonPackages ps
  );

  # FreeToken JIT-compiles CUDA kernels on first use (both its own and
  # flashinfer's), so the toolkit has to be there at *run* time, not just at
  # build time.
  cudaHome = freetoken.cudaRuntimeHome;

  # Triton's JIT cache is the one runtime cache that defaults outside
  # `$XDG_CACHE_HOME`: it lands in `$HOME/.triton`. That is more than
  # untidiness, because Triton compiles its CUDA driver shim into that
  # directory and then `dlopen()`s it. A `$HOME` mounted `noexec` — an
  # impermanence tmpfs, for instance, where only the persisted subdirectories
  # are real filesystems — therefore dies at the first kernel launch with
  # `ImportError: .../cuda_utils.cpython-*.so: failed to map segment from
  # shared object`, which says nothing about the mount that caused it. Point it
  # at the cache directory instead, which such setups do persist and do mount
  # executable.
  #
  # A default, not an override: `TRITON_CACHE_DIR` from the environment still
  # wins, which is how the NixOS module puts it under its own `cacheDir`.
  tritonCacheDefault = ''
    if [ -z "''${TRITON_CACHE_DIR:-}" ]; then
      export TRITON_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/freetoken/triton"
    fi
  '';
in
stdenvNoCC.mkDerivation {
  pname = "freetoken";
  inherit (freetoken) version;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    makeWrapper ${pythonEnv}/bin/ft $out/bin/ft \
      --set-default CUDA_HOME ${cudaHome} \
      --run ${lib.escapeShellArg tritonCacheDefault} \
      --prefix PATH : ${
        lib.makeBinPath [
          cudaHome
          gcc
          binutils
        ]
      } \
      --suffix LD_LIBRARY_PATH : ${addDriverRunpath.driverLink}/lib

    runHook postInstall
  '';

  passthru = {
    inherit
      cudaHome
      pythonEnv
      withAccel
      ;
    unwrapped = freetoken;
    python = python3;
  };

  meta = freetoken.meta // {
    description = "${freetoken.meta.description} (wrapped with a CUDA toolchain for runtime JIT)";
    mainProgram = "ft";
  };
}
