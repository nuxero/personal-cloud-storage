#!/usr/bin/env bash
#
# One-time setup: create the 'vmimport' service role that AWS VM Import/Export
# requires for `aws ec2 import-snapshot`. Safe to run more than once.
#
# Requires AWS CLI credentials with IAM permissions. Run from anywhere (your
# laptop is fine — this only touches IAM).
#
# Docs: https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html

set -euo pipefail

: "${IMPORT_BUCKET:?set IMPORT_BUCKET to the S3 bucket build.sh will upload the VHD to}"
ROLE_NAME="vmimport"

TRUST_POLICY="$(cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "vmie.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "sts:Externalid": "vmimport" } }
    }
  ]
}
JSON
)"

ACCESS_POLICY="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [ "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket" ],
      "Resource": [
        "arn:aws:s3:::${IMPORT_BUCKET}",
        "arn:aws:s3:::${IMPORT_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:ModifySnapshotAttribute",
        "ec2:CopySnapshot",
        "ec2:RegisterImage",
        "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)"

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "==> Role '${ROLE_NAME}' already exists, updating trust policy ..."
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}"
else
  echo "==> Creating role '${ROLE_NAME}' ..."
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}"
fi

echo "==> Attaching inline access policy (S3 bucket: ${IMPORT_BUCKET}) ..."
aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name vmimport-access \
  --policy-document "${ACCESS_POLICY}"

echo "==> Done. The 'vmimport' role is ready for aws ec2 import-snapshot."
