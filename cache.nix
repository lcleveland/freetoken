# The substituter that serves this flake's CUDA closure prebuilt.
#
# Nothing here comes from cache.nixos.org: the CUDA redistributables are
# unfree, so hydra never builds them, and torch's closure contains them. Without
# a CUDA cache, enabling FreeToken means compiling torch and flashinfer locally
# -- hours of it.
#
# cache.nixos-cuda.org is the CUDA maintainers' cache (it replaced
# cuda-maintainers.cachix.org in November 2025). It carries nixpkgs built with
# `cudaSupport = true`, which at the nixpkgs revision this flake pins covers
# torch, triton, flashinfer, nvidia-cutlass-dsl and cuda-bindings -- every
# expensive path in the closure.
{
  url = "https://cache.nixos-cuda.org";
  publicKey = "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=";
}
