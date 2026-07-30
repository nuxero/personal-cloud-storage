{ config, pkgs, lib, modulesPath, ... }:

# Personal Cloud Storage — NixOS Configuration
#
# Declarative configuration for a WebDAV server backed by S3.
# Architecture: Caddy (TLS + auth) -> rclone (WebDAV -> S3)
#
# Deployment:
#   1. Launch a NixOS AMI on EC2 (t4g.small, arm64)
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
  # stateVersion is set per-machine in secrets.nix — it must match the NixOS
  # version used at initial deployment and should never be changed afterward.
  system.stateVersion = secrets.stateVersion;
  networking.hostName = "storage";

  # Limit boot entries to prevent /boot from filling up (EFI partition is only 249MB).
  boot.loader.systemd-boot.configurationLimit = 2;

  # --- Auto-upgrades ---
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "04:00";
  };

  # Garbage-collect old generations daily (keep only last 3 days)
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 3d";
  };

  # Deduplicate identical files in the Nix store
  nix.settings.auto-optimise-store = true;

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
        # --- CORS for Diffuse music player (https://diffuse.sh) ---
        # Diffuse is a static web app that needs cross-origin access to WebDAV.
        @cors_preflight method OPTIONS
        @cors_origin header Origin https://diffuse.sh

        # Handle CORS preflight requests (no auth required)
        handle @cors_preflight {
            header Access-Control-Allow-Origin "https://diffuse.sh"
            header Access-Control-Allow-Methods "GET, HEAD, PROPFIND, OPTIONS"
            header Access-Control-Allow-Headers "Authorization, Content-Type, Depth, Range"
            header Access-Control-Allow-Credentials "true"
            header Access-Control-Max-Age "86400"
            respond 204
        }

        # RetroArch user — restricted to /retroarch/* only.
        # This password is stored in plain text by RetroArch, so treat it
        # as disposable. If compromised, only game saves are exposed.
        @retroarch_path path /retroarch/*
        handle @retroarch_path {
            basic_auth {
                ${secrets.retroarchUser} ${secrets.retroarchPasswordHash}
                ${secrets.adminUser} ${secrets.adminPasswordHash}
            }
            reverse_proxy localhost:8080
        }

        # Music (Diffuse) user — restricted to /media/music/* only.
        # Read-only WebDAV access for the Diffuse music player.
        @music_path path /media/music/*
        handle @music_path {
            basic_auth {
                ${secrets.diffuseUser} ${secrets.diffusePasswordHash}
                ${secrets.adminUser} ${secrets.adminPasswordHash}
            }
            # Add CORS headers on actual responses for Diffuse
            @cors_actual header Origin https://diffuse.sh
            header @cors_actual Access-Control-Allow-Origin "https://diffuse.sh"
            header @cors_actual Access-Control-Allow-Credentials "true"
            header @cors_actual Access-Control-Expose-Headers "Content-Length, Content-Type"
            reverse_proxy localhost:8080
        }

        # Admin user — full access to all paths (/backups/*, /media/*, etc.)
        handle {
            basic_auth {
                ${secrets.adminUser} ${secrets.adminPasswordHash}
            }
            # Add CORS headers for admin paths too (Diffuse can use admin creds)
            @cors_admin header Origin https://diffuse.sh
            header @cors_admin Access-Control-Allow-Origin "https://diffuse.sh"
            header @cors_admin Access-Control-Allow-Credentials "true"
            header @cors_admin Access-Control-Expose-Headers "Content-Length, Content-Type"
            reverse_proxy localhost:8080
        }
      '';
    };
  };

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
      # maxretry is set high enough to allow non-preemptive WebDAV clients
      # (which generate 2-3 legitimate 401 challenge-response cycles per connection)
      # while still catching brute-force attacks within a tight window.
      caddy-auth.settings = {
        enabled = true;
        port = "http,https";
        filter = "caddy-auth";
        logpath = "/var/log/caddy/access-*.log";
        backend = "auto";
        maxretry = 20;
        findtime = 60;
        bantime = 3600;
      };
      # Caddy path scanning / vulnerability probes (404 floods)
      caddy-botscan.settings = {
        enabled = true;
        port = "http,https";
        filter = "caddy-botscan";
        logpath = "/var/log/caddy/access-*.log";
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
