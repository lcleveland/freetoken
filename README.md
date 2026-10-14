# freetoken-nix

A Nix package, nixpkgs overlay and NixOS module for
[FreeToken](https://github.com/FlashML-org/FreeToken) — FlashML's edge-native
Mixture-of-Experts serving engine for running frontier-scale open-weight models
on consumer NVIDIA hardware.

Upstream ships a PyPI wheel and an `install.sh`; neither fits NixOS. This flake
builds FreeToken from source against PyTorch's own cu130 wheels (patched for
Nix, on CUDA 13), wraps `ft` with the CUDA toolchain it needs to JIT kernels at
run time, and adds a `services.freetoken` module that runs `ft serve` as a
hardened systemd service.

It also packages **FreeToken Desktop**, the GUI, with a proper launcher entry
and its engine pointed at the Nix `ft` — see [Desktop GUI](#desktop-gui).

## Requirements

- `x86_64-linux` with an NVIDIA GPU and the proprietary driver loaded
  (`hardware.graphics.enable = true` plus `hardware.nvidia.*`). The torch here
  is a CUDA 13 build, so the driver has to be r580 or newer.
- Unfree packages allowed — CUDA, and the CuteDSL runtime `flashlib` pulls in.
- Bandwidth and disk: the closure is ~4–5 GiB downloaded. Nothing in it takes
  more than a few minutes to build; see [Build cost](#build-cost).

## Try it

```console
$ nix run github:lcleveland/freetoken -- --version
$ nix run github:lcleveland/freetoken -- serve --model ~/models/Qwen3.6-35B-A3B
$ curl http://127.0.0.1:1919/v1/chat/completions -H 'Content-Type: application/json' \
    -d '{"model":"Qwen3.6-35B-A3B","messages":[{"role":"user","content":"hi"}]}'
```

`nix run` gives you the whole CLI — `ft serve`, `ft shell`, `ft ctl`,
`ft launch`, `ft checkpoint`, `ft bench bw`.

## Run it as a service

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    freetoken.url = "github:lcleveland/freetoken";
    freetoken.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, freetoken, ... }: {
    nixosConfigurations.gpu-box = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        freetoken.nixosModules.freetoken
        {
          services.freetoken = {
            enable = true;
            model = "/var/lib/freetoken/models/Qwen3.6-35B-A3B";
          };
        }
        ./configuration.nix
      ];
    };
  };
}
```

A complete, bootable example lives in [`examples/flake.nix`](examples/flake.nix).

Importing `nixosModules.freetoken` defaults `services.freetoken.package` to this
flake's own build, which is always made against a CUDA-enabled nixpkgs. Nothing
else in your system is rebuilt with `cudaSupport` because of it.

`services.freetoken.model` is the only required setting. It takes a local
directory (Hugging Face safetensors or FTW), or a Hugging Face repo id that is
downloaded into the state directory on first start.

### Options

| Option | Default | Meaning |
|---|---|---|
| `services.freetoken.enable` | `false` | Run `ft serve` as a systemd service. |
| `services.freetoken.package` | this flake's build | The `ft` package to run. |
| `services.freetoken.model` | *(required)* | Checkpoint path or Hugging Face repo id. |
| `services.freetoken.host` | `"127.0.0.1"` | Bind address. |
| `services.freetoken.port` | `1919` | Bind port. |
| `services.freetoken.openFirewall` | `false` | Open that port. |
| `services.freetoken.user` / `.group` | `null` | Run as this account instead of a `DynamicUser`. |
| `services.freetoken.stateDir` | `/var/lib/freetoken` | `HOME`, downloaded checkpoints, `ft bench bw` profiles. |
| `services.freetoken.cacheDir` | `/var/cache/freetoken` | JIT kernel caches (Triton, torch extensions, flashinfer). |
| `services.freetoken.settings` | `{ }` | `ft serve` flags, keyed by flag name without `--`. |
| `services.freetoken.extraArgs` | `[ ]` | Arguments appended verbatim. |
| `services.freetoken.environment` | `{ }` | Extra environment variables (`FREETOKEN_*`, `HF_*`, …). |
| `services.freetoken.environmentFile` | `null` | `EnvironmentFile=` for secrets such as `HF_TOKEN`. |
| `services.freetoken.binaryCache.enable` | `true` | Add the CUDA binary cache, which saves unpacking NVIDIA's libraries locally. |

`settings` maps one-to-one onto the flags in
[upstream's CLI reference](https://github.com/FlashML-org/FreeToken/blob/main/docs/cli.md):
`true` passes the bare flag, `false` and `null` drop it, a list repeats the flag,
anything else becomes `--flag value`.

```nix
services.freetoken.settings = {
  gpu = 1;                      # nvidia-smi index, or a GPU UUID prefix
  "served-model-name" = "local";
  "max-running-requests" = 8;
  "moe-backend" = "hybrid";     # run `ft bench bw` before pinning this
  "moe-cache-auto" = true;
};
```

Very little needs setting: dtype, attention backend, MoE backend and cache
sizes, KV capacity and the tool-call/reasoning parsers all resolve from the
checkpoint and the GPU.

### Talking to the server

The module puts `ft` on `environment.systemPackages`, so:

```console
$ ft ctl health
$ ft ctl stats
$ ft shell                      # attach a terminal chat to the running server
$ ft launch claude              # point a coding agent at it
```

### Security

FreeToken's HTTP API has **no authentication**. The default bind is loopback;
anything else means every client that can reach the port can run inference
against your GPU and read the served model, so put a proxy that authenticates in
front of it first. The module warns when `host` is not loopback.

The unit runs under a `DynamicUser` with `ProtectSystem=strict`, an empty
capability set, a closed device policy that only allows `/dev/nvidia*`, and a
`@system-service` syscall filter. Two knobs are deliberately relaxed: `MemoryDenyWriteExecute` is off, because
Triton, numba and torch's extension loader all generate code at run time, and
`LimitMEMLOCK` is unlimited, because expert banks are pinned in host RAM. Override anything through
`systemd.services.freetoken.serviceConfig`.

`ProtectHome=` is `read-only` when the model path is under `/home`, and `true`
otherwise.

## Desktop GUI

FreeToken Desktop is the GUI: model library, chat console, engine start/stop and
live cache/VRAM tuning.

```nix
{
  # nixosModules.freetoken carries this too; nixosModules.desktop is the GUI alone.
  programs.freetoken-desktop.enable = true;
}
```

`nixosModules.desktop` stands on its own — a workstation that only runs the GUI
does not need the server module. Imported that way it takes its engine from this
flake's `ft`; with the bare `modules/desktop.nix` and the overlay it takes
`pkgs.freetoken`.

That installs the app system-wide with its `.desktop` entry and hicolor icons,
so it appears in application launchers (GNOME, KDE, rofi, …) as **FreeToken
Desktop** — upstream's own entry ships an empty `Categories=`, which leaves it
unfiled in most launchers, so this package writes its own. From a terminal it is
`freetoken-desktop`.

| Option | Default | Meaning |
|---|---|---|
| `programs.freetoken-desktop.enable` | `false` | Install the GUI and its launcher entry. |
| `programs.freetoken-desktop.package` | this flake's build | The app package. |
| `programs.freetoken-desktop.engine` | the configured server package, else `pkgs.freetoken` | The `ft` the GUI drives, as `FREETOKEN_FT_BIN`. |
| `programs.freetoken-desktop.modelsDir` | `null` | Model library directory (`FREETOKEN_MODELS_DIR`). |
| `programs.freetoken-desktop.environment` | `{ }` | Extra environment baked into the app's wrapper. |

Three things worth knowing:

- **It manages its own engine.** The GUI starts and stops `ft serve` itself, so
  enabling `services.freetoken` as well means two processes racing for port
  1919. Pick one, or move the service to another port; the module warns when it
  sees both.
- **The `engine` option is what makes it work on NixOS.** Left unset, the app
  falls back to the installer it bundles, which builds a uv venv under
  `~/.freetoken` from PyPI wheels — that will not run here. The module wires
  `FREETOKEN_FT_BIN` to the Nix `ft` instead.
- **Its in-app updater cannot work**, since it wants to replace a binary in the
  Nix store. Bump the package instead.

The app is closed source — upstream publishes only the AppImage/`.deb`/pacman
bundles — so this repackages the `.deb` and it is marked `unfree` and
`binaryNativeCode`. If the window comes up blank on the NVIDIA driver, set
`programs.freetoken-desktop.environment.WEBKIT_DMABUF_RENDERER_FORCE_SHM = "1"`,
which is what the app itself asks for on the WebKitGTK nixpkgs ships.

## Runtime caches

`ft` compiles CUDA kernels on first use — Triton's own, flashinfer's, torch C++
extensions — and caches the results so later runs start fast. Under
`services.freetoken` they all go to `cacheDir`. Started from the GUI or a shell
they go to `$XDG_CACHE_HOME` (`~/.cache`), with two redirects in this flake's
`ft`: Triton's default `~/.triton` becomes `$XDG_CACHE_HOME/freetoken/triton`,
and flashinfer's `~/.cache/flashinfer` becomes
`$XDG_CACHE_HOME/freetoken/flashinfer/<store path>`. All of it is safe to
delete; the next run recompiles.

flashinfer gets one directory per build because its own cache is keyed only on
its version and the GPU, while the `build.ninja` it leaves there names its
sources by store path. Once a rebuild and a garbage collection remove those
paths, the next run dies on its first request with `norm.cu ... missing and no
known rule to make it`. The cost is that old directories pile up until you
delete them.

The redirect is not tidiness. Triton compiles a CUDA driver shim into its cache
directory and then `dlopen()`s it, so a cache on a `noexec` mount fails at the
first kernel launch with

```
ImportError: .../cuda_utils.cpython-314-x86_64-linux-gnu.so: failed to map segment from shared object
```

which names the file but not the mount that rejected it. This bites the
impermanence layout in particular, where `/home` is a `noexec` tmpfs and only
the persisted subdirectories are real filesystems — `~/.triton` is not usually
one of them, `~/.cache` usually is. If you hit that error anyway, the cache
directory it names is on a mount without `exec`: persist it, or point
`TRITON_CACHE_DIR` somewhere that has it.

## Use the overlay instead

If you already build your system with `nixpkgs.config.cudaSupport = true`:

```nix
{
  nixpkgs.overlays = [ freetoken.overlays.default ];
  environment.systemPackages = [ pkgs.freetoken ];
}
```

`overlays.default` leaves torch alone, so it builds against the from-source
torch your nixpkgs already uses. That torch is 2.13, and the FreeToken packaged
here needs 2.14, so on its own it builds a combination upstream does not
support. Add `overlays.binary-torch` before it to get the same wheel stack this
flake's packages use:

```nix
nixpkgs.overlays = [ freetoken.overlays.binary-torch freetoken.overlays.default ];
```

It replaces `pkgs.python3` and `pkgs.cudaPackages` wholesale, so everything else
in your system that uses either moves to the wheel torch and CUDA 13 as well.

The overlay adds `pkgs.freetoken` (the wrapped CLI) and `pkgs.freetoken-desktop`
(the GUI, already pointed at `pkgs.freetoken`), plus
`pkgs.python3Packages.freetoken` and `pkgs.python3Packages.flashlib` — the one
dependency nixpkgs does not carry — for composing your own Python environment.

## Packages

| Output | What it is |
|---|---|
| `packages.x86_64-linux.freetoken` | `ft`, wrapped with a CUDA toolchain for runtime JIT. The default. |
| `packages.x86_64-linux.freetoken-triton` | The same without flashinfer; falls back to the pure-Triton attention backend. |
| `packages.x86_64-linux.freetoken-wheel` | An alias for `freetoken`, kept for configurations that name it. |
| `packages.x86_64-linux.freetoken-desktop` | The GUI, wired to the `ft` above. Unfree, prebuilt binary. |
| `packages.x86_64-linux.python3Packages-freetoken` | The bare Python package. |
| `packages.x86_64-linux.python3Packages-flashlib` | flashlib 0.4.0, FreeToken's expert-cache kernel library. |

### How this differs from `pip install freetoken[accel]`

- **It tracks upstream `main`**, not a release tag, because `main` is where
  torch 2.14 support landed. The `ft --version` string still reads 0.1.3.
- **No `sglang-kernel`.** Upstream's `accel` extra is flashinfer plus
  `sglang-kernel`, an ABI-locked binary wheel with no nixpkgs package. `accel`
  here is flashinfer only; FreeToken falls back to its own Triton kernels for
  what `sgl_kernel` would have provided.
- **torch, triton and torchvision match upstream's pins** (2.14.1, 3.8.0,
  0.29.1) because they are PyTorch's own wheels. Everything else comes from
  nixpkgs, and a few pins are relaxed to fit it — `transformers<5.17` against
  nixpkgs' 5.17, plus `gguf` and `apache-tvm-ffi`, which nixpkgs versions
  differently. Those ceilings are "last verified", not known breakage, but it is
  a real difference from what upstream tests.
- **Kernels are JIT-compiled**, not taken from upstream's prebuilt
  `freetoken-kernel-cache` wheel. flashinfer is installed in JIT mode too
  rather than nixpkgs' AOT build, which is hours of compiling. The first
  requests after an upgrade pay for the compile; results are cached under
  `cacheDir`.

## Build cost

Enabling FreeToken does not mean compiling PyTorch. torch, triton and
torchvision are PyTorch's own cu130 wheels, and NCCL and NVSHMEM come from
NVIDIA's PyPI wheels: downloads plus `autoPatchelf`, not source builds.
nixpkgs' own torch is a source build that only `cache.nixos-cuda.org` caches,
and it trails upstream releases by weeks — FreeToken already needs torch 2.14,
which nixpkgs does not have yet.

The rest of the closure is small. Counted from an empty store, at this flake's
pinned nixpkgs:

| | derivations built | downloaded |
| --- | --- | --- |
| With `cache.nixos-cuda.org` | **33** | 4.3 GiB |
| Without it | **95** | 1.2 GiB from caches, plus NVIDIA's CUDA archives fetched directly |

Either way, the only real compiles are `cuda-bindings` (Cython), `safetensors`
(Rust), `numba`, FreeToken's two C++ extension files and flashinfer's JIT-mode
install. The rest unpacks wheels and archives and joins `CUDA_HOME`. On the
16-core test machine, with the cache and part of the closure already present,
the build took about five minutes, most of it download.

[`cache.nixos-cuda.org`](https://github.com/SomeoneSerge/nixpkgs-cuda-ci) is the
CUDA maintainers' cache. All it saves here is the CUDA 13.3 redistributables
(cuDNN, cuBLAS, nvcc and the rest), which `cache.nixos.org` never carries
because they are unfree. Without it, Nix downloads the same archives from NVIDIA
and unpacks them locally. `services.freetoken.binaryCache` (on by default) adds
it to the built system's `nix.conf`, so it takes effect from the rebuild *after*
the one that enables FreeToken. To use it on the first build too, pass it on the
command line:

```console
$ sudo nixos-rebuild switch \
    --option extra-substituters https://cache.nixos-cuda.org \
    --option extra-trusted-public-keys "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
```

`services.freetoken.binaryCache.enable = false` opts out if you would rather not
trust a third-party cache.

The wheels are pinned in
[`overlays/binary-torch.nix`](overlays/binary-torch.nix), ahead of nixpkgs'
`torch-bin`, which is still at 2.13. The pins can go once nixpkgs catches up.

`freetoken-triton` drops flashinfer entirely if you can live with the Triton
attention backend.

## Updating to a new FreeToken release

Bump `version` and the `rev` in
[`pkgs/freetoken/default.nix`](pkgs/freetoken/default.nix) and refresh the hash
(use a tag such as `v0.1.4` in place of the commit once a release covers it):

```console
$ nix run nixpkgs#nurl -- https://github.com/FlashML-org/FreeToken <commit-or-tag>
```

Then re-check the dependency list in that file against upstream's
`pyproject.toml`, since the relaxations above are version-specific. If upstream
moves its torch pin, the torch, triton and torchvision wheels in
[`overlays/binary-torch.nix`](overlays/binary-torch.nix) move with it. The cp314
cu130 wheels are listed at `https://download.pytorch.org/whl/cu130/torch/`, and
`nix-prefetch-url` gives their hashes.

The GUI is versioned separately. Its current release is in
[`update/stable.json`](https://github.com/FlashML-org/FreeToken-Web/blob/main/update/stable.json)
on the FreeToken-Web repo; bump `version` in
[`pkgs/freetoken-desktop/default.nix`](pkgs/freetoken-desktop/default.nix) and
refresh the hash with `nix-prefetch-url` on the `.deb` asset.

## Development

```console
$ nix flake check          # evaluates every output, runs the module tests
$ nix fmt                  # nixfmt via treefmt
$ nix develop              # nixfmt-tree, nix-update, nurl
```

`flake.lock` pins the nixpkgs everything here was built and tested against;
`nix flake update` moves it. Consumers who would rather not have a second
nixpkgs in their closure want
`inputs.freetoken.inputs.nixpkgs.follows = "nixpkgs"`, which is fine as long as
theirs is recent enough to carry `flashinfer-python` and `apache-tvm-ffi`.

The module tests build the generated systemd unit against a stub `ft` and assert
the command line, so they run anywhere. There is no NixOS VM test: serving needs
a real GPU.

## License

The Nix expressions here are MIT. FreeToken itself is
[Apache 2.0](https://github.com/FlashML-org/FreeToken/blob/main/LICENSE).
