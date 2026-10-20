# Nixpkgs overlay adding FreeToken and the one dependency nixpkgs is missing.
#
#   nixpkgs.overlays = [ freetoken.overlays.default ];
#
# gives you `pkgs.freetoken` (the wrapped `ft` CLI) and `pkgs.freetoken-desktop`
# (the GUI), plus `pkgs.python3Packages.freetoken` and
# `pkgs.python3Packages.flashlib`.
#
# FreeToken is CUDA-only: unless `nixpkgs.config.cudaSupport` is set, the torch
# it resolves against is the CPU build and `ft serve` will not find a GPU.
final: prev: {
  freetoken = final.callPackage ./pkgs/freetoken/wrapper.nix { };

  # The GUI. Unfree: upstream publishes it as a prebuilt binary only. It picks
  # up `final.freetoken` as the engine it drives.
  freetoken-desktop = final.callPackage ./pkgs/freetoken-desktop { };

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: pyPrev: {
      flashlib = pyFinal.callPackage ./pkgs/flashlib { };
      freetoken = pyFinal.callPackage ./pkgs/freetoken { };

      # ponytail: cuda-bindings/cuda-core pin cython<3.3 but nixpkgs moved to
      # 3.3.0. Mirrors NixOS/nixpkgs#575576; drop once that lands in nixpkgs.
      cuda-bindings = pyPrev.cuda-bindings.override { cython = pyFinal.cython_3_2; };
      cuda-core = pyPrev.cuda-core.override { cython = pyFinal.cython_3_2; };
    })
  ];
}
