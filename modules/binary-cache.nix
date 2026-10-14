# Point Nix at the cache that serves this flake's prebuilt closure, so
# installing FreeToken downloads instead of builds.
#
# Declared separately from the server and GUI modules because it is useful with
# either of them, and because it configures Nix rather than FreeToken.
{
  config,
  lib,
  ...
}:

let
  cfg = config.services.freetoken.binaryCache;
  defaults = import ../cache.nix;
in
{
  options.services.freetoken.binaryCache = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = defaults.url != "";
      defaultText = lib.literalExpression "the flake has a cache configured in cache.nix";
      description = ''
        Add {option}`services.freetoken.binaryCache.url` to Nix's substituters
        and trust its key.

        The CUDA redistributables are unfree, so `cache.nixos.org` never
        carries them. Without this cache Nix fetches NVIDIA's archives directly
        and unpacks them locally: slower, but nothing is compiled either way,
        since torch comes from PyTorch's wheels.

        It configures the system being built, so the rebuild that first builds
        FreeToken still runs under the previous `nix.conf`. Pass the cache to
        that first `nixos-rebuild` with `--option extra-substituters` and
        `--option extra-trusted-public-keys` if you want it used there too.
      '';
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = defaults.url;
      defaultText = lib.literalExpression "the url from cache.nix";
      example = "https://freetoken-nix.cachix.org";
      description = "Binary cache serving this flake's closure.";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      default = defaults.publicKey;
      defaultText = lib.literalExpression "the publicKey from cache.nix";
      example = "freetoken-nix.cachix.org-1:0000000000000000000000000000000000000000000=";
      description = ''
        The cache's public key. Nix refuses unsigned paths from a substituter
        it does not trust, so this is not optional.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.url != "" && cfg.publicKey != "";
        message = "services.freetoken.binaryCache needs both url and publicKey; without the key Nix will not accept anything the cache serves. Fill them in here or in cache.nix.";
      }
    ];

    nix.settings = {
      extra-substituters = [ cfg.url ];
      extra-trusted-public-keys = [ cfg.publicKey ];
    };
  };
}
