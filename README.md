# freetoken-nix

A Nix package, nixpkgs overlay and NixOS module for
[FreeToken](https://github.com/FlashML-org/FreeToken) — FlashML's edge-native
Mixture-of-Experts serving engine for running frontier-scale open-weight models
on consumer NVIDIA hardware.

Upstream ships a PyPI wheel and an `install.sh`; neither fits NixOS. This flake
builds FreeToken from source against nixpkgs' own torch/CUDA stack, wraps `ft`
with the CUDA toolchain it needs to JIT kernels at run time, and adds a
`services.freetoken` module that runs `ft serve` as a hardened systemd service.

It also packages **FreeToken Desktop**, the GUI, with a proper launcher entry
and its engine pointed at the Nix `ft` — see [Desktop GUI](#desktop-gui).

## Requirements

- `x86_64-linux` with an NVIDIA GPU and the proprietary driver loaded
  (`hardware.graphics.enable = true` plus `hardware.nvidia.*`; upstream asks for
  r580+ for CUDA 13, though this flake builds against whichever CUDA version
  nixpkgs' torch uses).
- Unfree packages allowed — CUDA, and the CuteDSL runtime `flashlib` pulls in.
- Disk and patience the first time: with `cudaSupport`, torch and friends are
  built from source unless you point Nix at a cache that has them (see
  [Build cost](#build-cost)).

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

## Use the overlay instead

If you already build your system with `nixpkgs.config.cudaSupport = true`:

```nix
{
  nixpkgs.overlays = [ freetoken.overlays.default ];
  environment.systemPackages = [ pkgs.freetoken ];
}
```

The overlay adds `pkgs.freetoken` (the wrapped CLI) and `pkgs.freetoken-desktop`
(the GUI, already pointed at `pkgs.freetoken`), plus
`pkgs.python3Packages.freetoken` and `pkgs.python3Packages.flashlib` — the one
dependency nixpkgs does not carry — for composing your own Python environment.

## Packages

| Output | What it is |
|---|---|
| `packages.x86_64-linux.freetoken` | `ft`, wrapped with a CUDA toolchain for runtime JIT. The default. |
| `packages.x86_64-linux.freetoken-triton` | The same without flashinfer; far smaller, falls back to the pure-Triton attention backend. |
| `packages.x86_64-linux.freetoken-desktop` | The GUI, wired to the `ft` above. Unfree, prebuilt binary. |
| `packages.x86_64-linux.python3Packages-freetoken` | The bare Python package. |
| `packages.x86_64-linux.python3Packages-flashlib` | flashlib 0.3.0, FreeToken's expert-cache kernel library. |

### How this differs from `pip install freetoken[accel]`

- **No `sglang-kernel`.** Upstream's `accel` extra is flashinfer plus
  `sglang-kernel`, an ABI-locked binary wheel built against torch 2.11 with no
  nixpkgs package. `accel` here is flashinfer only; FreeToken falls back to its
  own Triton kernels for what `sgl_kernel` would have provided.
- **Relaxed version pins.** Upstream pins `torch>=2.11,<2.12`,
  `triton==3.6.0` and `numpy<2.5`; nixpkgs carries torch 2.13, triton 3.7 and
  numpy 2.5. Those ceilings are "last verified", not known breakage, and
  everything is built from source against the versions actually present — but it
  is a real difference from what upstream tests.
- **Kernels are JIT-compiled**, not taken from upstream's prebuilt
  `freetoken-kernel-cache` wheel. The first request after an upgrade pays for
  the compile; results are cached under `cacheDir`.

## Build cost

`cudaSupport = true` puts you off the `cache.nixos.org` binary path for torch and
everything downstream of it. Add the community CUDA cache before your first
build:

```nix
nix.settings = {
  substituters = [ "https://cuda-maintainers.cachix.org" ];
  trusted-public-keys = [
    "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
  ];
};
```

`freetoken-triton` (no flashinfer) is much cheaper if you can live with the
Triton attention backend.

## Updating to a new FreeToken release

Bump `version` in [`pkgs/freetoken/default.nix`](pkgs/freetoken/default.nix) and
refresh the hash:

```console
$ nix run nixpkgs#nurl -- https://github.com/FlashML-org/FreeToken v0.1.3
```

Then re-check the dependency list in that file against upstream's
`pyproject.toml`, since the relaxations above are version-specific.

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
