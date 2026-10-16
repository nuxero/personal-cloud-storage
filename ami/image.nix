# Custom NixOS amazon AMI with a larger ESP (/boot) partition.
#
# WHY THIS EXISTS
# ---------------
# The stock NixOS AMI ships a 256MiB ESP (shows as ~249M for /boot). On arm64,
# each NixOS generation stores a ~90MB kernel + initrd in /boot, so even 2-3
# generations overflow it — and switch-to-configuration writes the NEW kernel
# before pruning old ones (nixpkgs#23926), briefly needing room for one extra.
# That tiny ESP is baked into the stock image and cannot be grown by relaunching
# (boot.growPartition only grows root). So we build our own image with a bigger
# ESP via make-disk-image.nix's `bootSize` parameter.
#
# WHAT THIS PRODUCES
# ------------------
# A VHD disk image (config.system.build.amazonImage) for aarch64, with:
#   - EFI/GPT layout, ESP sized to `bootSizeMiB` below (default 1024MiB)
#   - ext4 root that auto-resizes to the EBS volume on boot
# Upload + register as an AMI using ./build.sh.
#
# NOTE: This image intentionally does NOT bake in configuration.nix/secrets.nix.
# It is a clean base (like the stock NixOS AMI) — you still scp your config and
# run `nixos-rebuild switch`, exactly as documented in the README. The only
# difference from stock is the larger /boot.

{
  # Pin nixpkgs for reproducible image builds. Bump this rev to rebuild on a
  # newer base. (The running server tracks nixos-unstable independently via
  # system.autoUpgrade; this pin only affects the initial AMI contents.)
  nixpkgsRev ? "nixos-unstable",
  pkgsSrc ? builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz",

  # ESP size in MiB. 1024 gives comfortable headroom for several arm64
  # generations at boot.loader.grub.configurationLimit = 3.
  bootSizeMiB ? 1024,
}:

let
  nixos = import "${pkgsSrc}/nixos" {
    system = "aarch64-linux";
    configuration =
      { config, lib, pkgs, modulesPath, ... }:
      {
        imports = [
          "${modulesPath}/virtualisation/amazon-image.nix"
        ];

        # EFI boot (arm64 EC2 uses UEFI).
        ec2.efi = true;

        # Enlarge the ESP. The amazon image's build derivation is defined in
        # nixos/maintainers/scripts/ec2/amazon-image.nix, which for the ext4
        # (non-ZFS) path calls make-disk-image.nix with partitionTableType
        # "efi". We override the resulting build to pass a larger bootSize.
        #
        # make-disk-image.nix accepts bootSize as a string like "1024M".
        system.build.amazonImage = lib.mkForce (
          import "${pkgsSrc}/nixos/lib/make-disk-image.nix" {
            inherit lib config pkgs;
            inherit (config.virtualisation) diskSize;

            name = "nixos-amazon-image-bigboot";
            configFile = pkgs.writeText "configuration.nix" ''
              { modulesPath, ... }: {
                imports = [ "''${modulesPath}/virtualisation/amazon-image.nix" ];
                ec2.efi = true;
              }
            '';

            fsType = "ext4";
            partitionTableType = "efi";
            bootSize = "${toString bootSizeMiB}M";

            format = "vpc"; # VHD, what AWS import-snapshot expects
            contents = [ ];
          }
        );
      };
  };
in
  nixos.config.system.build.amazonImage
