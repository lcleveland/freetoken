# NixOS module for FreeToken Desktop, the GUI that drives a local `ft` engine.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.freetoken-desktop;

  envVars =
    lib.optionalAttrs (cfg.modelsDir != null) { FREETOKEN_MODELS_DIR = cfg.modelsDir; }
    // cfg.environment;

  withEngine =
    if cfg.engine == null then cfg.package else cfg.package.override { freetoken = cfg.engine; };

  # Bake the settings into the app's own wrapper rather than the login session,
  # so they apply however it is started and need no re-login.
  finalPackage =
    if envVars == { } then
      withEngine
    else
      withEngine.overrideAttrs (old: {
        preFixup = (old.preFixup or "") + ''
          gappsWrapperArgs+=(
            ${lib.concatStringsSep "\n  " (
              lib.mapAttrsToList (
                name: value: "--set-default ${lib.escapeShellArg name} ${lib.escapeShellArg value}"
              ) envVars
            )}
          )
        '';
      });
in
{
  options.programs.freetoken-desktop = {
    enable = lib.mkEnableOption ''
      FreeToken Desktop, the GUI control panel for the FreeToken engine.

      Installs the app system-wide together with its `.desktop` entry and
      icons, so it shows up in application launchers
    '';

    package = lib.mkPackageOption pkgs "freetoken-desktop" { };

    engine = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = config.services.freetoken.package;
      defaultText = lib.literalExpression "config.services.freetoken.package";
      description = ''
        The `ft` package the GUI drives, wired in as `FREETOKEN_FT_BIN`.

        Without it the app falls back to its bundled installer, which builds a
        uv venv under `~/.freetoken` from PyPI wheels — that does not work on
        NixOS. Set to `null` only if
        {option}`programs.freetoken-desktop.package` is something that takes no
        `freetoken` argument.
      '';
    };

    modelsDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/srv/models";
      description = ''
        Directory the app's model library reads and downloads into
        (`FREETOKEN_MODELS_DIR`). Must be writable by whoever runs the GUI.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        WEBKIT_DMABUF_RENDERER_FORCE_SHM = "1";
      };
      description = ''
        Extra environment variables baked into the app's wrapper. Each is a
        default, so it can still be overridden per-invocation from a shell.

        `WEBKIT_DMABUF_RENDERER_FORCE_SHM = "1"` is the fix upstream asks for
        when the window comes up blank on the proprietary NVIDIA driver.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "programs.freetoken-desktop: upstream publishes the desktop app for x86_64-linux only.";
      }
    ];

    warnings =
      lib.optional
        (
          config.services.freetoken.enable
          && config.services.freetoken.port == 1919
          && config.services.freetoken.host == "127.0.0.1"
        )
        ''
          Both services.freetoken and programs.freetoken-desktop are enabled. The GUI
          starts and stops its own `ft serve` on port 1919, which is the port the
          service already holds, so whichever loses the race fails to bind. Move the
          service to another port, or leave the engine to the GUI and disable
          services.freetoken.
        '';

    environment.systemPackages = [ finalPackage ];
  };
}
