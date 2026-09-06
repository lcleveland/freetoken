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
