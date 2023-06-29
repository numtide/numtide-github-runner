inputs:
{ lib, config, pkgs, ... }:
let
  cfg = config.services.numtide-github-runner;

  inherit (lib)
    literalExpression
    mdDoc
    mkEnableOption
    mkIf
    mkOption
    optionalAttrs
    range
    types
    ;
in
{
  imports = [
    "${inputs.queued-build-hook}/module.nix"
  ];

  options.services.numtide-github-runner = {
    enable = mkEnableOption "numtide-github-runner";

    url = mkOption {
      description = "URL of the repo or organization to connect to.";
      type = types.str;
    };

    githubApp = mkOption {
      description = mdDoc ''
        Authenticate runners using GitHub App
      '';
      type = types.submodule {
        options = {
          id = mkOption {
            type = types.str;
            description = mdDoc "GitHub App ID";
          };
          login = mkOption {
            type = types.str;
            description = mdDoc "GitHub login used to register the application";
          };
          privateKeyFile = mkOption {
            type = types.path;
            description = mdDoc ''
              The full path to a file containing the GitHub App private key.
            '';
          };
        };
      };
    };

    name = mkOption {
      description = "Prefix name of the runners";
      type = types.str;
      default = "numtide-github-runner";
    };

    runnerGroup = mkOption {
      type = types.nullOr types.str;
      description = mdDoc ''
        Name of the runner group to add this runner to (defaults to the default runner group).

        Changing this option triggers a new runner registration.
      '';
      default = null;
    };

    replace = mkOption {
      type = types.bool;
      description = mdDoc ''
        Replace any existing runner with the same name.

        Without this flag, registering a new runner with the same name fails.
      '';
      default = false;
    };

    serviceOverrides = mkOption {
      type = types.attrs;
      description = mdDoc ''
        Overrides for the systemd service. Can be used to adjust the sandboxing options.
      '';
      example = {
        ProtectHome = false;
      };
      default = { };
    };

    package = mkOption {
      type = types.package;
      description = mdDoc ''
        Which github-runner derivation to use.
      '';
      default = pkgs.github-runner;
      defaultText = literalExpression "pkgs.github-runner";
    };

    count = mkOption {
      description = "Number of github actions runner to deploy";
      default = 4;
      type = types.int;
    };

    # TODO: merge this with the binary-cache
    cachix = {
      cacheName = mkOption {
        description = "Cachix cache name";
        type = types.nullOr types.str;
        default = null;
      };

      tokenFile = mkOption {
        description = "Path to the token";
        type = types.str;
      };
    };

    binary-cache = {
      script = mkOption {
        description = mdDoc "Script used by asynchronous process to upload Nix packages to the binary cache, without requiring the use of Cachix.";
        type = types.nullOr types.str;
        default = null;
      };
      enqueueScript = mkOption {
        description = mdDoc ''
          Script content responsible for enqueuing newly-built packages and passing them to the daemon.

          Although the default configuration should suffice, there may be situations that require customized handling of specific packages.
          For example, it may be necessary to process certain packages synchronously using the 'queued-build-hook wait' command, or to ignore certain packages entirely.
        '';
        type = types.str;
        default = "";
      };
      credentials = mkOption {
        description = mdDoc ''
          Credentials to load by startup. Keys that are UPPER_SNAKE will be loaded as env vars. Values are absolute paths to the credentials.
        '';
        type = types.attrsOf types.str;
        default = { };

        example = {
          AWS_SHARED_CREDENTIALS_FILE = "/run/keys/aws-credentials";
          binary-cache-key = "/run/keys/binary-cache-key";
        };
      };
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      description = mdDoc ''
        Extra packages to add to `PATH` of the service to make them available to workflows.
      '';
      default = [ ];
    };

    extraEnvironment = mkOption {
      type = types.attrs;
      description = mdDoc ''
        Extra environment variables to set for the runner, as an attrset.
      '';
      example = {
        GIT_CONFIG = "/path/to/git/config";
      };
      default = { };
    };

    extraLabels = mkOption {
      type = types.listOf types.str;
      description = mdDoc ''
        Extra labels in addition to the default (`["self-hosted", "Linux", "X64"]`).

        Changing this option triggers a new runner registration.
      '';
      example = literalExpression ''[ "nixos" ]'';
      default = [ "nix" ];
    };
  };

  config = mkIf cfg.enable {
    # Required to run unmodified binaries fetched via dotnet in a dev environment.
    programs.nix-ld.enable = true;

    # Automatically sync all the locally built artifacts to cachix.
    services.cachix-watch-store = mkIf (cfg.cachix.cacheName != null) {
      enable = true;
      cacheName = cfg.cachix.cacheName;
      cachixTokenFile = cfg.cachix.tokenFile;
      jobs = 4;
    };

    queued-build-hook = mkIf (cfg.binary-cache.script != null)
      ({
        enable = true;
        postBuildScriptContent = cfg.binary-cache.script;
        credentials = cfg.binary-cache.credentials;
      } // (optionalAttrs (cfg.binary-cache.enqueueScript != "") {
        enqueueScriptContent = cfg.binary-cache.enqueueScript;
      }));

    systemd.services = builtins.listToAttrs (map (n:
      rec {
        name = "${cfg.name}-${n}";
        value = import ./service.nix {
          inherit name lib pkgs cfg;
          systemdDir = "numtide-github-runner/${n}";
          nix = config.nix.package;
        };
      }
    ) (range 1 cfg.count));
  };
}
