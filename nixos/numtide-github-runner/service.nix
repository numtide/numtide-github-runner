{ lib
, pkgs
, name
, nix
, cfg
, config

, systemdDir
  # %t: Runtime directory root (usually /run); see systemd.unit(5)
, runtimeDir ? "%t/${systemdDir}"
  # %S: State directory root (usually /var/lib); see systemd.unit(5)
, stateDir ? "%S/${systemdDir}"
  # %L: Log directory root (usually /var/log); see systemd.unit(5)
, logsDir ? "%L/${systemdDir}"
  # Name of file stored in service state directory
, currentConfigTokenFilename ? ".current-token"
}:

with lib;
let
  currentConfigTokenPath = "$STATE_DIRECTORY/${currentConfigTokenFilename}";
  # Wrapper script which expects the full path of the state, runtime and logs
  # directory as arguments. Overrides the respective systemd variables to provide
  # unambiguous directory names. This becomes relevant, for example, if the
  # caller overrides any of the StateDirectory=, RuntimeDirectory= or LogDirectory=
  # to contain more than one directory. This causes systemd to set the respective
  # environment variables with the path of all of the given directories, separated
  # by a colon.
  writeScript = name: lines: pkgs.writeShellScript "${svcName}-${name}.sh" ''
    set -euo pipefail

    STATE_DIRECTORY="$1"
    RUNTIME_DIRECTORY="$2"
    LOGS_DIRECTORY="$3"

    ${lines}
  '';

  runnerRegistrationConfig = {
    inherit name;
    inherit (cfg) url runnerGroup extraLabels;
  };
  newConfigPath = builtins.toFile "${svcName}-config.json" (builtins.toJSON runnerRegistrationConfig);
  currentConfigPath = "$STATE_DIRECTORY/.nixos-current-config.json";
  newConfigTokenPath = "$STATE_DIRECTORY/.new-token";

  runnerCredFiles = [
    ".credentials"
    ".credentials_rsaparams"
    ".runner"
  ];

  app_token = pkgs.writeShellApplication {
    name = "fetch_access_token";
    runtimeInputs = with pkgs;[ jq openssl curl ];
    text = ./app_token.sh;
  };

  token = pkgs.writeShellApplication {
    name = "fetch_runner_token";
    runtimeInputs = with pkgs;[ jq curl ];
    text = ./token.sh;
  };

  remove_existing_runner = pkgs.writeShellApplication {
    name = "remove_existing_runner";
    runtimeInputs = with pkgs;[ jq curl ];
    text = ./remove_existing_runner.sh;
  };

  unconfigureRunnerGitHubApp = writeScript "unconfigure-github-app" ''
    set -euo pipefail
    export APP_ID=${cfg.githubApp.id}
    export APP_LOGIN=${cfg.githubApp.login}
    export RUNNER_SCOPE="org"
    export ORG_NAME="${cfg.githubApp.login}"
    export APP_PRIVATE_KEY=$(cat ${cfg.githubApp.privateKeyFile})
    ACCESS_TOKEN=$(${app_token}/bin/fetch_access_token)
    export ACCESS_TOKEN
    umask 000
    export RUNNER_NAME=${escapeShellArg cfg.name}

    unregister_previous_runner() {
      ${remove_existing_runner}/bin/remove_existing_runner
    }
    copy_tokens() {
      ${token}/bin/fetch_runner_token | ${pkgs.jq}/bin/jq -r '.token' > ${newConfigTokenPath}
      ls -l ${newConfigTokenPath}
      install --mode=600 ${newConfigTokenPath} "${currentConfigTokenPath}"
    }
    clean_state() {
      find "$STATE_DIRECTORY/" -mindepth 1 -delete
      copy_tokens 
    }
    unregister_previous_runner
    clean_state
  '';

  configureRunner = writeScript "configure" ''
    if [[ -e "${newConfigTokenPath}" ]]; then
      echo "Configuring GitHub Actions Runner"
      args=(
        --unattended
        --disableupdate
        --work "$RUNTIME_DIRECTORY"
        --url ${escapeShellArg cfg.url}
        --labels ${escapeShellArg (concatStringsSep "," cfg.extraLabels)}
        --name ${escapeShellArg cfg.name}
        --ephemeral
        --replace
        ${optionalString (cfg.runnerGroup != null) "--runnergroup ${escapeShellArg cfg.runnerGroup}"}
      )
      # If the token file contains a PAT (i.e., it starts with "ghp_" or "github_pat_"), we have to use the --pat option,
      # if it is not a PAT, we assume it contains a registration token and use the --token option
      token=$(<"${newConfigTokenPath}")
      if [[ "$token" =~ ^ghp_* ]] || [[ "$token" =~ ^github_pat_* ]]; then
        args+=(--pat "$token")
      else
        args+=(--token "$token")
      fi
      ${cfg.package}/bin/config.sh "''${args[@]}"
      # Move the automatically created _diag dir to the logs dir
      mkdir -p  "$STATE_DIRECTORY/_diag"
      cp    -r  "$STATE_DIRECTORY/_diag/." "$LOGS_DIRECTORY/"
      rm    -rf "$STATE_DIRECTORY/_diag/"
      # Cleanup token from config
      rm "${newConfigTokenPath}"
      # Symlink to new config
      ln -s '${newConfigPath}' "${currentConfigPath}"
    fi
  '';

  setupRuntimeDir = writeScript "setup-runtime-dirs" ''
    # Link _diag dir
    ln -s "$LOGS_DIRECTORY" "$RUNTIME_DIRECTORY/_diag"

    # Link the runner credentials to the runtime dir
    ln -s "$STATE_DIRECTORY"/{${lib.concatStringsSep "," runnerCredFiles}} "$RUNTIME_DIRECTORY/"
  '';

  unregisterScript = writeScript "unregister-runner" ''
    RUNNER_ALLOW_RUNASROOT=1 ${cfg.package}/bin/config.sh remove --token "$(cat ${currentConfigTokenPath})" || true
  '';
in
{
  description = "GitHub Actions runner";

  wantedBy = [ "multi-user.target" ];
  after = [ "network.target" ];

  environment = {
    HOME = runtimeDir;
    RUNNER_ROOT = stateDir;
  } // cfg.extraEnvironment;

  path = [
    config.nix.package
    pkgs.bash
    pkgs.cachix
    pkgs.coreutils
    pkgs.git
    pkgs.glibc.bin
    pkgs.gnutar
    pkgs.gzip
    pkgs.jq
    pkgs.nix-eval-jobs
    pkgs.openssh
  ] ++ cfg.extraPackages;

  serviceConfig = {
    ExecStart = "${cfg.package}/bin/Runner.Listener run --startuptype service";

    # Does the following, sequentially:
    # - If the module configuration or the token has changed, purge the state directory,
    #   and create the current and the new token file with the contents of the configured
    #   token. While both files have the same content, only the later is accessible by
    #   the service user.
    # - Configure the runner using the new token file. When finished, delete it.
    # - Set up the directory structure by creating the necessary symlinks.
    ExecStartPre = map (x: "${x} ${escapeShellArgs [ stateDir runtimeDir logsDir ]}") (builtins.filter (x: x != "") [
      "+${unconfigureRunnerGitHubApp}" # runs as root
      configureRunner
      setupRuntimeDir
    ]);

    ExecStopPost = map (x: "${x} ${escapeShellArgs [ stateDir runtimeDir logsDir ]}") [
      "-+${unregisterScript}"
    ];

    # Because we're running in ephemeral mode, restart the service on-exit (i.e., successful de-registration of the runner)
    # to trigger a fresh registration.
    Restart = "always";
    # If the runner exits with `ReturnCode.RetryableError = 2`, always restart the service:
    # https://github.com/actions/runner/blob/40ed7f8/src/Runner.Common/Constants.cs#L146
    RestartForceExitStatus = [ 2 ];

    # Contains _diag
    LogsDirectory = [ systemdDir ];
    # Default RUNNER_ROOT which contains ephemeral Runner data
    RuntimeDirectory = [ systemdDir ];
    # Home of persistent runner data, e.g., credentials
    StateDirectory = [ systemdDir ];
    StateDirectoryMode = "0700";
    WorkingDirectory = runtimeDir;

    InaccessiblePaths = [
      # Token file path given in the configuration, if visible to the service
      "-${cfg.githubApp.privateKeyFile}"
      # Token file in the state directory
      "${stateDir}/${currentConfigTokenFilename}"
    ];

    KillSignal = "SIGINT";

    # Hardening (may overlap with DynamicUser=)
    # The following options are only for optimizing:
    # systemd-analyze security github-runner
    AmbientCapabilities = "";
    CapabilityBoundingSet = "";
    # ProtectClock= adds DeviceAllow=char-rtc r
    DeviceAllow = [ "/dev/kvm" ];
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateMounts = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    RemoveIPC = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    UMask = "0066";
    ProtectProc = "invisible";
    SystemCallFilter = [
      "~@clock"
      "~@cpu-emulation"
      "~@module"
      "~@mount"
      "~@obsolete"
      "~@raw-io"
      "~@reboot"
      "~capset"
      "~setdomainname"
      "~sethostname"
    ];
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];

    # Needs network access
    PrivateNetwork = false;
    # Cannot be true due to Node
    MemoryDenyWriteExecute = false;

    # The more restrictive "pid" option makes `nix` commands in CI emit
    # "GC Warning: Couldn't read /proc/stat"
    # You may want to set this to "pid" if not using `nix` commands
    ProcSubset = "all";
    # Coverage programs for compiled code such as `cargo-tarpaulin` disable
    # ASLR (address space layout randomization) which requires the
    # `personality` syscall
    # You may want to set this to `true` if not using coverage tooling on
    # compiled code
    LockPersonality = false;

    # Note that this has some interactions with the User setting; so you may
    # want to consult the systemd docs if using both.
    DynamicUser = true;
  };
}
