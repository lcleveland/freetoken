# Nixpkgs overlay adding FreeToken and the one dependency nixpkgs is missing.
#
#   nixpkgs.overlays = [ freetoken.overlays.default ];
#
# gives you `pkgs.freetoken` (the wrapped `ft` CLI) plus
# `pkgs.python3Packages.freetoken` and `pkgs.python3Packages.flashlib`.
#
# FreeToken is CUDA-only: unless `nixpkgs.config.cudaSupport` is set, the torch
# it resolves against is the CPU build and `ft serve` will not find a GPU.
final: prev: {
  freetoken = final.callPackage ./pkgs/freetoken/wrapper.nix { };

  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pyFinal: _pyPrev: {
      flashlib = pyFinal.callPackage ./pkgs/flashlib { };
      freetoken = pyFinal.callPackage ./pkgs/freetoken { };
    })
  ];
}
