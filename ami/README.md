# Custom NixOS AMI with a larger `/boot`

The stock NixOS AMI ships a **256MiB ESP** (shows as ~249M for `/boot`). On
arm64 each generation stores a ~90MB kernel + initrd there, so a few generations
overflow it — and `switch-to-configuration` writes the new kernel *before*
pruning old ones ([nixpkgs#23926](https://github.com/NixOS/nixpkgs/issues/23926)),
briefly needing room for one extra. That ESP is baked into the image and cannot
be grown by relaunching (`boot.growPartition` only grows root).

This directory builds a drop-in replacement AMI identical to stock **except the
ESP is 1GiB**. Your deployment flow (scp `configuration.nix` + `nixos-rebuild
switch`) is unchanged — you just launch from this AMI instead.

## Files

| File | Purpose |
|------|---------|
| `image.nix` | Nix expression producing the aarch64 amazon VHD with a larger ESP |
| `build.sh` | Builds the VHD, imports it as a snapshot, registers the AMI |
| `setup-vmimport-role.sh` | One-time IAM `vmimport` role setup (required by VM Import/Export) |

## Why not Packer?

Packer's NixOS path (`amazon-ebssurrogate`) provisions a surrogate instance and
imperatively installs onto an attached volume — it fights NixOS's declarative
model and doesn't cleanly expose ESP sizing. The native nixpkgs image build
(`config.system.build.amazonImage` → import-snapshot → register-image) is
simpler and gives exact control over `bootSize`. So: no Packer.

## Build procedure

### 1. Launch a throwaway aarch64 builder

NixOS arm64 images are built most easily on an arm64 host. Launch a temporary
instance (terminate it when done):

- **Instance type:** `c7g.xlarge` (or any `*g.*` Graviton; more vCPU = faster)
- **AMI:** any recent NixOS arm64 AMI, or Amazon Linux 2023 arm64 + install Nix
- **Disk:** 30GB+ (image builds need scratch space)
- **IAM instance profile:** allow S3 (to the import bucket) + EC2 VM import +
  `register-image`. Simplest: attach a role with `AmazonEC2FullAccess` +
  `AmazonS3FullAccess` for the short life of this builder, or scope it down.

If using Amazon Linux instead of a NixOS builder, install Nix first:

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
```

### 2. One-time: create the vmimport role

From any machine with IAM-capable credentials:

```bash
export IMPORT_BUCKET=your-vmimport-bucket   # an S3 bucket you own in the target region
./setup-vmimport-role.sh
```

### 3. Build + register the AMI

On the aarch64 builder, from the repo root:

```bash
export AWS_REGION=us-east-1
export IMPORT_BUCKET=your-vmimport-bucket
# optional overrides:
# export BOOT_SIZE_MIB=1024
# export NIXPKGS_REV=nixos-unstable
# export AMI_NAME=nixos-bigboot-v1

./ami/build.sh
```

The script prints the new **AMI ID** at the end.

### 4. Deploy with the new AMI

Plug the AMI ID into CloudFormation's `LatestAmiId` and deploy as usual:

```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name cloud-storage \
  --parameter-overrides \
    KeyPairName=your-key \
    SshCidr=YOUR_IP/32 \
    LatestAmiId=ami-NEWID \
  --capabilities CAPABILITY_IAM
```

Then follow the normal server setup in the top-level README (scp
`configuration.nix`, create `secrets.nix`, `nixos-rebuild switch`). Because the
instance is stateless (all data in S3) and the Elastic IP re-associates, this is
a safe replace.

### 5. Clean up

Terminate the throwaway builder instance. Optionally empty the import bucket;
the registered AMI + its snapshot are what you keep.

## Verifying `/boot` size after deploy

```bash
ssh -i your-key.pem admin@ELASTIC_IP 'df -h /boot'
# Filesystem  Size  Used Avail Use% Mounted on
# /dev/nvme0n1p1  ~1016M  ...        /boot
```

## Tuning the ESP size

`BOOT_SIZE_MIB` (env) / `bootSizeMiB` (`image.nix` arg) controls the ESP. 1024MiB
pairs well with `boot.loader.grub.configurationLimit = 3` on arm64. Raise it if
you bump the generation limit.
