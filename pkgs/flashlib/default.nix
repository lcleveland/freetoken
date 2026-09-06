{
  lib,
  stdenv,
  buildPythonPackage,
  fetchPypi,

  # build-system
  setuptools,

  # dependencies
  numba,
  numpy,
  nvidia-cutlass-dsl,
  torch,
  triton,
  tqdm,
}:

buildPythonPackage rec {
  pname = "flashlib";
  version = "0.3.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-t2mZOjDwD2z0QyzSqddCoYEW9XgkdTPvtbEmrAgb5As=";
  };

  build-system = [ setuptools ];

  dependencies = [
    numba
    numpy
    torch
    tqdm
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    nvidia-cutlass-dsl
    triton
  ];

  # Every kernel wants a real GPU; the test suite is not shipped in the sdist anyway.
  doCheck = false;

  # flashlib defers torch/triton to first attribute access, so a plain import is
  # cheap and works without a GPU.
  pythonImportsCheck = [ "flashlib" ];

  meta = {
    description = "High-performance ML primitives, applications and cost API — Triton + CuteDSL kernels for NVIDIA GPUs";
    homepage = "https://pypi.org/project/flashlib/";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
  };
}
