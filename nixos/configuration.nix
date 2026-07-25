{ config, pkgs, lib, modulesPath, ... }:

# Personal Cloud Storage — NixOS Configuration
#
# Declarative configuration for a WebDAV server backed by S3.
# Architecture: Caddy (TLS + auth) -> rclone (WebDAV -> S3)
#
# Deployment:
#   1. Launch a NixOS AMI on EC2 (t4g.nano, arm64)
#   2. Copy this file to /etc/nixos/configuration.nix
#   3. Create /etc/nixos/secrets.nix with your credentials (see secrets.nix.example)
#   4. Run: sudo nixos-rebuild switch
#
# All services, hardening, and fail2ban are configured declaratively.
# No imperative scripts needed.

let
  # Import secrets (not tracked in git — see secrets.nix.example)
  secrets = import ./secrets.nix;
in
{
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
  ];

  # --- System ---
  system.stateVersion = "25.05";
  networking.hostName = "storage";

  # --- Auto-upgrades ---
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "04:00";
  };

  # Garbage-collect old generations weekly
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # --- Packages ---
  environment.systemPackages = with pkgs; [
    rclone
    vim
    htop
    curl
  ];

  # --- SSH ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # --- User ---
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = secrets.sshPublicKeys;
  };
  security.sudo.wheelNeedsPassword = false;

  # --- Firewall ---
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 80 443 22 ];
  };

  # --- rclone WebDAV service ---
  # Serves S3 bucket as WebDAV on localhost:8080 (no auth, no TLS — Caddy handles both)
  systemd.services.rclone-webdav = {
    description = "rclone WebDAV server (S3 backend)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.rclone}/bin/rclone serve webdav"
        ":s3,provider=AWS,region=${secrets.s3Region},env_auth=true:${secrets.s3Bucket}"
        "--addr 127.0.0.1:8080"
        "--vfs-cache-mode minimal"
        "--vfs-cache-max-age 1h"
        "--cache-dir /var/cache/rclone"
        "--server-read-timeout 5m"
        "--server-write-timeout 5m"
      ];
      Restart = "always";
      RestartSec = 5;

      # Hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      CacheDirectory = "rclone";
      DynamicUser = true;
    };
  };

  # --- Caddy (TLS + authentication + reverse proxy) ---
  services.caddy = {
    enable = true;
    virtualHosts.${secrets.domain} = {
      extraConfig = ''
        log {
            output file /var/log/caddy/access.log {
                roll_size 10MiB
                roll_keep 5
                roll_keep_for 14d
            }
        }
        basic_auth {
            ${secrets.webdavUser} ${secrets.webdavPasswordHash}
        }
        reverse_proxy localhost:8080
      '';
    };
  };

  # Ensure Caddy log directory exists
  systemd.tmpfiles.rules = [
    "d /var/log/caddy 0755 caddy caddy -"
    "f /var/log/caddy/access.log 0644 caddy caddy -"
  ];

  # --- fail2ban ---
  services.fail2ban = {
    enable = true;
    maxretry = 5;
    bantime = "1h";
    bantime-increment = {
      enable = true;
      multipliers = "1 2 4 8 16 32 64";
      maxtime = "168h";
      overalljails = true;
    };
    jails = {
      # Caddy WebDAV authentication brute-force (401 responses)
      caddy-auth.settings = {
        enabled = true;
        port = "http,https";
        filter = "caddy-auth";
        logpath = "/var/log/caddy/access.log";
        backend = "auto";
        maxretry = 5;
        findtime = 600;
        bantime = 3600;
      };
      # Caddy path scanning / vulnerability probes (404 floods)
      caddy-botscan.settings = {
        enabled = true;
        port = "http,https";
        filter = "caddy-botscan";
        logpath = "/var/log/caddy/access.log";
        backend = "auto";
        maxretry = 15;
        findtime = 300;
        bantime = 3600;
      };
    };
  };

  # fail2ban filter definitions
  environment.etc = {
    "fail2ban/filter.d/caddy-auth.local".text = ''
      [Definition]
      failregex = "remote_ip":"<HOST>".*"status":401
      datepattern = "ts":{Epoch}
      ignoreregex =
    '';
    "fail2ban/filter.d/caddy-botscan.local".text = ''
      [Definition]
      failregex = "remote_ip":"<HOST>".*"status":404
      datepattern = "ts":{Epoch}
      ignoreregex =
    '';
  };
}
