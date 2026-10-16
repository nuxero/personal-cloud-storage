#!/usr/bin/env bash
#
# Build a custom NixOS aarch64 AMI with a larger /boot (ESP) partition, then
# register it as an AMI in your AWS account.
#
# RUN THIS ON A THROWAWAY aarch64 EC2 INSTANCE (see ami/README.md for how to
# launch one). It needs: Nix, the AWS CLI, and an instance role (or credentials)
# allowed to use S3 + EC2 VM import.
#
# What it does:
#   1. nix-build ami/image.nix  -> produces a VHD disk image
#   2. uploads the VHD to an S3 bucket
#   3. aws ec2 import-snapshot  -> imports the VHD as an EBS snapshot
#   4. aws ec2 register-image   -> registers an AMI from that snapshot
#
# Output: the new AMI ID, which you plug into CloudFormation's LatestAmiId.

set -euo pipefail

# --- Config (override via environment) ---
: "${AWS_REGION:?set AWS_REGION, e.g. us-east-1}"
: "${IMPORT_BUCKET:?set IMPORT_BUCKET to an S3 bucket you own in AWS_REGION}"
BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-1024}"
AMI_NAME="${AMI_NAME:-nixos-bigboot-$(date +%Y%m%d-%H%M%S)}"
ARCH="arm64"

echo "==> Building NixOS amazon image (bootSize=${BOOT_SIZE_MIB}MiB, aarch64) ..."
# result/ will contain nixos-*.vhd and nix-support/image-info.json
nix-build ami/image.nix --argstr nixpkgsRev "${NIXPKGS_REV:-nixos-unstable}" \
  --arg bootSizeMiB "${BOOT_SIZE_MIB}" \
  -o result

VHD_PATH="$(find -L result -name '*.vhd' -print -quit)"
if [[ -z "${VHD_PATH}" ]]; then
  echo "ERROR: no .vhd produced under result/" >&2
  exit 1
fi
echo "==> Built image: ${VHD_PATH}"

S3_KEY="ami-import/$(basename "${VHD_PATH}")"
echo "==> Uploading to s3://${IMPORT_BUCKET}/${S3_KEY} ..."
aws s3 cp "${VHD_PATH}" "s3://${IMPORT_BUCKET}/${S3_KEY}" --region "${AWS_REGION}"

echo "==> Importing snapshot ..."
IMPORT_TASK_ID="$(aws ec2 import-snapshot \
  --region "${AWS_REGION}" \
  --description "${AMI_NAME}" \
  --disk-container "Format=VHD,UserBucket={S3Bucket=${IMPORT_BUCKET},S3Key=${S3_KEY}}" \
  --query 'ImportTaskId' --output text)"
echo "    import task: ${IMPORT_TASK_ID}"

echo "==> Waiting for snapshot import to complete (this can take several minutes) ..."
SNAPSHOT_ID=""
while :; do
  read -r STATUS SNAPSHOT_ID < <(aws ec2 describe-import-snapshot-tasks \
    --region "${AWS_REGION}" \
    --import-task-ids "${IMPORT_TASK_ID}" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.[Status,SnapshotId]' \
    --output text)
  echo "    status: ${STATUS}  snapshot: ${SNAPSHOT_ID:-<pending>}"
  case "${STATUS}" in
    completed) break ;;
    deleted|error) echo "ERROR: import failed (${STATUS})" >&2; exit 1 ;;
    *) sleep 15 ;;
  esac
done
echo "==> Snapshot ready: ${SNAPSHOT_ID}"

echo "==> Registering AMI '${AMI_NAME}' ..."
AMI_ID="$(aws ec2 register-image \
  --region "${AWS_REGION}" \
  --name "${AMI_NAME}" \
  --architecture "${ARCH}" \
  --root-device-name /dev/xvda \
  --virtualization-type hvm \
  --ena-support \
  --boot-mode uefi \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=${SNAPSHOT_ID},VolumeType=gp3,DeleteOnTermination=true}" \
  --query 'ImageId' --output text)"

echo ""
echo "================================================================"
echo " New AMI registered: ${AMI_ID}  (${ARCH}, ${BOOT_SIZE_MIB}MiB /boot)"
echo " Plug it into CloudFormation:  LatestAmiId=${AMI_ID}"
echo "================================================================"
