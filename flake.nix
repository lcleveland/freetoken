{
  description = "Nix package and NixOS module for FreeToken, the edge-native MoE serving engine";

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
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
          overlays = [ self.overlays.default ];
        };
    in
    {
      overlays.default = import ./overlay.nix;

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.freetoken;

          # `ft` wrapped with the CUDA toolchain it needs for runtime kernel JIT.
          freetoken = pkgs.freetoken;

          # The same thing without flashinfer's fused kernels: a far smaller
          # build that falls back to the pure-Triton attention backend.
          freetoken-triton = pkgs.freetoken.override { withAccel = false; };

          # The bare python packages, for composing your own environment.
          python3Packages-freetoken = pkgs.python3Packages.freetoken;
          python3Packages-flashlib = pkgs.python3Packages.flashlib;
        }
      );

      nixosModules = {
        default = self.nixosModules.freetoken;

        freetoken =
          { pkgs, ... }:
          {
            imports = [ ./modules/freetoken.nix ];
            # Default to this flake's CUDA-enabled build, so importing the module
            # is enough — no overlay and no system-wide `cudaSupport` needed.
            services.freetoken.package =
              lib.mkDefault
                self.packages.${pkgs.stdenv.hostPlatform.system}.freetoken;
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
