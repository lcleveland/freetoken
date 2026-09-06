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
    (pyFinal: _pyPrev: {
      flashlib = pyFinal.callPackage ./pkgs/flashlib { };
      freetoken = pyFinal.callPackage ./pkgs/freetoken { };
    })
  ];
}
