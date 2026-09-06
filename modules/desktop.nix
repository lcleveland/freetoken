# NixOS module for FreeToken Desktop, the GUI that drives a local `ft` engine.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.freetoken-desktop;

  # This module stands alone: `nixosModules.desktop` imports it without the
  # server module, so nothing below may assume `services.freetoken` is even a
  # declared option.
  server = config.services.freetoken or { };

  envVars =
    lib.optionalAttrs (cfg.modelsDir != null) { FREETOKEN_MODELS_DIR = cfg.modelsDir; }
    // cfg.environment;

  withEngine =
    if cfg.engine == null then
      cfg.package
    else if cfg.package ? override then
      cfg.package.override { freetoken = cfg.engine; }
    else
      throw (
        "programs.freetoken-desktop.package takes no `freetoken` argument to override, so the "
        + "engine cannot be wired into it. Set programs.freetoken-desktop.engine = null and put "
        + "FREETOKEN_FT_BIN into the app's environment yourself."
      );

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
      default =
        server.package or pkgs.freetoken or (throw (
          "programs.freetoken-desktop.engine has no default to fall back on: neither the "
          + "services.freetoken module nor this flake's overlay is in scope. Set it to the "
          + "`ft` package to drive, or to null to leave the app on its bundled installer."
        ));
      defaultText = lib.literalExpression ''
        config.services.freetoken.package, or pkgs.freetoken when
        the server module is not imported
      '';
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
        ((server.enable or false) && (server.port or null) == 1919 && (server.host or null) == "127.0.0.1")
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
