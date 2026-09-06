{
  description = "Nix package and NixOS module for FreeToken, the edge-native MoE serving engine";

  # Without this, `nix build`/`nix run` against this flake compiles torch and
  # flashinfer from source: cache.nixos.org carries no unfree CUDA. The NixOS
  # modules configure the same cache through
  # `services.freetoken.binaryCache`, which is what a `nixos-rebuild` needs --
  # nixConfig only reaches direct `nix` invocations, and only for trusted users.
  nixConfig = {
    extra-substituters = [ "https://cache.nixos-cuda.org" ];
    extra-trusted-public-keys = [
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # FreeToken is CUDA-only and upstream supports Linux x86_64.
      systems = [ "x86_64-linux" ];
      forAllSystems = lib.genAttrs systems;

      # FreeToken without CUDA is a checkpoint loader that cannot serve, so this
      # flake's own outputs are always built against a CUDA-enabled nixpkgs.
      # Consumers that already build their system with `cudaSupport` can skip
      # this and use `overlays.default` on their own nixpkgs instead.
      #
      # This is deliberately nixpkgs' stock CUDA stack -- from-source torch at
      # the default CUDA version -- because that is exactly what
      # cache.nixos-cuda.org has already built. Anything else (a newer CUDA, or
      # torch's own wheel) is a cache miss and means building it yourself.
      mkPkgs =
        {
          system,
          binaryTorch ? false,
        }:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
          overlays = lib.optional binaryTorch self.overlays.binary-torch ++ [ self.overlays.default ];
        };

      pkgsFor = system: mkPkgs { inherit system; };
    in
    {
      overlays = {
        default = import ./overlay.nix;

        # Opt-in, and rarely what you want: it swaps in torch's own cu130 wheel
        # and CUDA 13, which no public cache carries, so it trades an hour of
        # NCCL and flashinfer builds for a torch download. Only worth it if you
        # cannot use cache.nixos-cuda.org. It is also invasive -- it replaces
        # `pkgs.python3` and `pkgs.cudaPackages` wholesale.
        binary-torch = import ./overlays/binary-torch.nix;
      };

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.freetoken;

          # `ft` wrapped with the CUDA toolchain it needs for runtime kernel JIT.
          freetoken = pkgs.freetoken;

          # The same thing without flashinfer's fused kernels: falls back to the
          # pure-Triton attention backend.
          freetoken-triton = pkgs.freetoken.override { withAccel = false; };

          # Built against torch's own wheel and CUDA 13 rather than nixpkgs'
          # cached stack. See `overlays.binary-torch` for when that is worth it.
          freetoken-wheel =
            (mkPkgs {
              inherit system;
              binaryTorch = true;
            }).freetoken;

          # The GUI control panel, pointed at the `ft` above.
          freetoken-desktop = pkgs.freetoken-desktop;

          # The bare python packages, for composing your own environment.
          python3Packages-freetoken = pkgs.python3Packages.freetoken;
          python3Packages-flashlib = pkgs.python3Packages.flashlib;
        }
      );

      nixosModules = {
        default = self.nixosModules.freetoken;

        # Everything: `services.freetoken` (the server) and
        # `programs.freetoken-desktop` (the GUI).
        freetoken =
          { pkgs, ... }:
          {
            imports = [
              ./modules/freetoken.nix
              ./modules/desktop.nix
              ./modules/binary-cache.nix
            ];
            # Default to this flake's CUDA-enabled builds, so importing the module
            # is enough — no overlay and no system-wide `cudaSupport` needed.
            services.freetoken.package =
              lib.mkDefault
                self.packages.${pkgs.stdenv.hostPlatform.system}.freetoken;
            programs.freetoken-desktop.package =
              lib.mkDefault
                self.packages.${pkgs.stdenv.hostPlatform.system}.freetoken-desktop;
          };

        # The GUI on its own, for a workstation that only drives an engine.
        # `services.freetoken` is not imported here, so the engine default that
        # the module would otherwise take from it is supplied directly.
        desktop =
          { pkgs, ... }:
          {
            imports = [
              ./modules/desktop.nix
              ./modules/binary-cache.nix
            ];
            programs.freetoken-desktop = {
              package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.freetoken-desktop;
              engine = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.freetoken;
            };
          };
      };

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;

          # Keep the module checks off the multi-gigabyte CUDA build: they are
          # about the generated unit, not about FreeToken itself.
          stubPackage = pkgs.writeShellScriptBin "ft" ''
            exec echo "$@"
          '';

          evalModule =
            module:
            (lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.freetoken
                {
                  services.freetoken.package = stubPackage;
                  # Enough of a system to evaluate; nothing here is built.
                  boot.loader.grub.enable = false;
                  fileSystems."/" = {
                    device = "none";
                    fsType = "tmpfs";
                  };
                  system.stateVersion = lib.trivial.release;
                }
                module
              ];
            }).config;

          failedAssertions = config: map (a: a.message) (builtins.filter (a: !a.assertion) config.assertions);
        in
        {
          module-eval =
            let
              config = evalModule {
                services.freetoken = {
                  enable = true;
                  model = "/var/lib/freetoken/models/Qwen3.6-35B-A3B";
                  port = 8080;
                  openFirewall = true;
                  settings = {
                    "moe-backend" = "hybrid";
                    "moe-cache-auto" = true;
                    "max-running-requests" = 8;
                    "memory-ratio" = 0.85;
                    "disable-moe-prefill-overlap" = false;
                  };
                  extraArgs = [ "--enable-cache-report" ];
                };
              };
              broken = failedAssertions config;
              service = config.systemd.services.freetoken;
            in
            assert broken == [ ] || throw "unexpected assertion failures: ${lib.concatStringsSep "; " broken}";
            pkgs.runCommand "freetoken-module-eval" { } ''
              cat > cmd <<'EOF'
              ${service.serviceConfig.ExecStart}
              EOF

              check() {
                grep -qF -- "$1" cmd || { echo "missing from ExecStart: $1"; cat cmd; exit 1; }
              }
              refute() {
                grep -qF -- "$1" cmd && { echo "unexpected in ExecStart: $1"; cat cmd; exit 1; }
                true
              }

              check "serve --model /var/lib/freetoken/models/Qwen3.6-35B-A3B"
              check "--host 127.0.0.1 --port 8080"
              check "--moe-backend hybrid"
              check "--moe-cache-auto"
              check "--max-running-requests 8"
              check "--memory-ratio 0.85"
              check "--enable-cache-report"
              # false-valued settings are dropped, not passed as a flag
              refute "--disable-moe-prefill-overlap"

              [ "${builtins.toString (config.networking.firewall.allowedTCPPorts or [ ])}" = "8080" ] \
                || { echo "openFirewall did not open the port"; exit 1; }

              touch $out
            '';

          # The dedicated options own --model/--host/--port; setting them through
          # `settings` too must be caught rather than silently duplicated.
          module-rejects-reserved-flags =
            let
              config = evalModule {
                services.freetoken = {
                  enable = true;
                  model = "some/model";
                  settings.host = "0.0.0.0";
                };
              };
              broken = failedAssertions config;
            in
            assert lib.any (lib.hasInfix "`host`") broken || throw "settings.host was not rejected";
            pkgs.runCommand "freetoken-module-rejects-reserved-flags" { } "touch $out";

          # The GUI must land in systemPackages with its launcher entry, and be
          # pointed at the configured engine rather than its own installer.
          desktop-module-eval =
            let
              # A stub that takes the same `freetoken` argument the real package
              # does, so the module's override path is exercised.
              stubDesktop = pkgs.callPackage (
                { writeShellScriptBin, freetoken }:
                writeShellScriptBin "freetoken-desktop" ''
                  echo engine=${lib.getExe freetoken}
                ''
              ) { freetoken = pkgs.writeShellScriptBin "ft" "exit 1"; };

              config = evalModule {
                programs.freetoken-desktop = {
                  enable = true;
                  package = stubDesktop;
                  modelsDir = "/srv/models";
                };
                services.freetoken = {
                  enable = true;
                  model = "/srv/models/Qwen3.6-35B-A3B";
                };
              };

              broken = failedAssertions config;
              installed = lib.findFirst (
                p: lib.hasInfix "freetoken-desktop" (p.name or "")
              ) null config.environment.systemPackages;
            in
            assert broken == [ ] || throw "unexpected assertion failures: ${lib.concatStringsSep "; " broken}";
            assert installed != null || throw "the GUI was not added to environment.systemPackages";
            # Enabling both means two things racing for port 1919; say so.
            assert
              lib.any (lib.hasInfix "port 1919") config.warnings
              || throw "no warning about the engine port collision";
            pkgs.runCommand "freetoken-desktop-module-eval" { } ''
              grep -qF -- "engine=${lib.getExe stubPackage}" ${lib.getExe installed} \
                || { echo "the GUI was not wired to the configured engine"; exit 1; }
              touch $out
            '';

          # The cache is the whole difference between "downloads" and "compiles
          # torch", so check the modules actually configure it.
          binary-cache-module =
            let
              cache = import ./cache.nix;
              config = evalModule {
                services.freetoken = {
                  enable = true;
                  model = "some/model";
                };
              };
              settings = config.nix.settings;
            in
            assert
              builtins.elem cache.url settings.extra-substituters
              || throw "the CUDA cache is not in extra-substituters";
            assert
              builtins.elem cache.publicKey settings.extra-trusted-public-keys
              || throw "the CUDA cache key is not trusted, so nix would refuse everything it serves";
            # And it must be possible to turn off: it is a third party.
            assert
              (evalModule {
                services.freetoken = {
                  enable = true;
                  model = "some/model";
                  binaryCache.enable = false;
                };
              }).nix.settings.extra-substituters or [ ] == [ ]
              || throw "binaryCache.enable = false did not remove the substituter";
            pkgs.runCommand "freetoken-binary-cache-module" { } "touch $out";

          # The GUI module must stand on its own: it is imported without the
          # server module, whose options it must therefore not reach into --
          # including for the `engine` default, which is left unset here on
          # purpose so that default is what gets evaluated.
          desktop-module-standalone =
            let
              stubEngine = pkgs.writeShellScriptBin "ft" "exit 1";
              # Same shape as the real package: takes a `freetoken` argument, so
              # the module's override path is what gets exercised.
              stubDesktop = pkgs.callPackage (
                { writeShellScriptBin, freetoken }:
                writeShellScriptBin "freetoken-desktop" ''
                  echo engine=${lib.getExe freetoken}
                ''
              ) { freetoken = pkgs.writeShellScriptBin "ft" "exit 1"; };

              config =
                (lib.nixosSystem {
                  inherit system;
                  modules = [
                    ./modules/desktop.nix
                    {
                      # Stand in for the overlay the module falls back on when
                      # services.freetoken is not in scope.
                      nixpkgs.pkgs = pkgs.extend (_: _: { freetoken = stubEngine; });
                      programs.freetoken-desktop = {
                        enable = true;
                        package = stubDesktop;
                      };
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "none";
                        fsType = "tmpfs";
                      };
                      system.stateVersion = lib.trivial.release;
                    }
                  ];
                }).config;

              broken = failedAssertions config;
              installed = lib.findFirst (
                p: lib.hasInfix "freetoken-desktop" (p.name or "")
              ) null config.environment.systemPackages;

              # The flake's own `nixosModules.desktop` must supply an engine
              # without the server module too. Only its type is checked, so the
              # real (very large) package is evaluated but never built.
              flakeEngine =
                (lib.nixosSystem {
                  inherit system;
                  modules = [
                    self.nixosModules.desktop
                    {
                      programs.freetoken-desktop = {
                        enable = true;
                        package = stubDesktop;
                      };
                      boot.loader.grub.enable = false;
                      fileSystems."/" = {
                        device = "none";
                        fsType = "tmpfs";
                      };
                      system.stateVersion = lib.trivial.release;
                    }
                  ];
                }).config.programs.freetoken-desktop.engine;
            in
            assert broken == [ ] || throw "unexpected assertion failures: ${lib.concatStringsSep "; " broken}";
            assert installed != null || throw "the GUI was not added to environment.systemPackages";
            # Forces the warnings, which also used to read services.freetoken.
            assert
              config.warnings == [ ]
              || throw "unexpected warnings without the server module: ${lib.concatStringsSep "; " config.warnings}";
            assert
              lib.isDerivation flakeEngine
              || throw "nixosModules.desktop left programs.freetoken-desktop.engine unusable";
            pkgs.runCommand "freetoken-desktop-module-standalone" { } ''
              grep -qF -- "engine=${lib.getExe stubEngine}" ${lib.getExe installed} \
                || { echo "the engine default did not resolve to pkgs.freetoken"; exit 1; }
              touch $out
            '';

          # A missing model must fail the build with the assertion, not with an
          # eval error somewhere inside the unit.
          module-requires-model =
            let
              config = evalModule { services.freetoken.enable = true; };
              broken = failedAssertions config;
            in
            assert
              lib.any (lib.hasInfix "services.freetoken.model") broken
              || throw "a missing model was not rejected";
            pkgs.runCommand "freetoken-module-requires-model" { } "touch $out";
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.nixfmt-tree
              pkgs.nix-update
              pkgs.nurl
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
