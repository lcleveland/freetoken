# A minimal NixOS system that serves a model with FreeToken.
#
#   nixos-rebuild switch --flake .#gpu-box
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    freetoken.url = "github:lcleveland/freetoken";
    # Optional: one nixpkgs instead of two. FreeToken is still built against a
    # CUDA-enabled instance of it, so this does not turn cudaSupport on for the
    # rest of your system.
    freetoken.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, freetoken, ... }:
    {
      nixosConfigurations.gpu-box = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          freetoken.nixosModules.freetoken

          (
            { config, pkgs, ... }:
            {
              # --- the NVIDIA driver FreeToken needs -------------------------
              nixpkgs.config.allowUnfree = true;
              hardware.graphics.enable = true;
              hardware.nvidia = {
                open = true; # RTX 20-series and newer
                modesetting.enable = true;
                package = config.boot.kernelPackages.nvidiaPackages.stable;
              };
              services.xserver.videoDrivers = [ "nvidia" ];

              # --- FreeToken -------------------------------------------------
              services.freetoken = {
                enable = true;
                model = "/var/lib/freetoken/models/Qwen3.6-35B-A3B";

                # Everything below is optional; `ft serve` derives sane values
                # from the checkpoint and the GPU on its own.
                settings = {
                  "served-model-name" = "local";
                  "max-running-requests" = 8;
                  # ft bench bw first, then pick a MoE backend deliberately:
                  # "moe-backend" = "hybrid";
                };
              };

              # The GUI, in your application launcher as "FreeToken Desktop".
              # It drives its own `ft serve`, so leave services.freetoken off
              # (or move it off port 1919) if you enable this.
              # programs.freetoken-desktop.enable = true;

              # Reach the API from the LAN. The API is unauthenticated, so only
              # do this on a network you trust, or put a proxy in front of it.
              # services.freetoken.host = "0.0.0.0";
              # services.freetoken.openFirewall = true;

              # --- the rest of a bootable system -----------------------------
              boot.loader.systemd-boot.enable = true;
              fileSystems."/" = {
                device = "/dev/disk/by-label/nixos";
                fsType = "ext4";
              };
              system.stateVersion = "25.11";
            }
          )
        ];
      };
    };
}
