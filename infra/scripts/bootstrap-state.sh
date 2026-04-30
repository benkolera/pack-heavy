#!/usr/bin/env bash
#
# Bootstrap Pulumi's S3 state bucket + KMS key (for secret encryption).
# Idempotent: safe to re-run.
#
# Pulumi can't store its own state in resources it manages, so the bucket
# and KMS key live outside the stack. This script creates them, enables
# versioning + SSE on the bucket, and prints the env-var snippet you
# should source before running pulumi.
#
# Usage:
#   ./infra/scripts/bootstrap-state.sh
#
# Env overrides:
#   AWS_REGION   (default: ap-southeast-2)
#   STATE_PREFIX (default: packheavy-pulumi-state)
#   KMS_ALIAS    (default: alias/packheavy-pulumi)

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
STATE_PREFIX="${STATE_PREFIX:-packheavy-pulumi-state}"
KMS_ALIAS="${KMS_ALIAS:-alias/packheavy-pulumi}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${STATE_PREFIX}-${ACCOUNT_ID}-${AWS_REGION}"

echo "→ Account: ${ACCOUNT_ID}"
echo "→ Region:  ${AWS_REGION}"
echo "→ Bucket:  ${BUCKET}"
echo "→ KMS:     ${KMS_ALIAS}"
echo

# 1. State bucket
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "✓ Bucket exists"
else
  echo "→ Creating bucket"
  aws s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
fi

aws s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled >/dev/null
echo "✓ Versioning enabled"

aws s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' >/dev/null
echo "✓ SSE-S3 enabled"

aws s3api put-public-access-block \
  --bucket "${BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
echo "✓ Public access blocked"

# 2. KMS key for secret encryption
if KMS_KEY_ID=$(aws kms describe-key --key-id "${KMS_ALIAS}" --region "${AWS_REGION}" \
  --query KeyMetadata.KeyId --output text 2>/dev/null); then
  echo "✓ KMS key exists: ${KMS_KEY_ID}"
else
  echo "→ Creating KMS key"
  KMS_KEY_ID=$(aws kms create-key \
    --region "${AWS_REGION}" \
    --description "Pulumi state secret encryption for packheavy" \
    --query KeyMetadata.KeyId --output text)
  aws kms create-alias \
    --region "${AWS_REGION}" \
    --alias-name "${KMS_ALIAS}" \
    --target-key-id "${KMS_KEY_ID}" >/dev/null
  echo "✓ KMS key created: ${KMS_KEY_ID}"
fi

cat <<EOF

Done. To use this backend:

  pulumi login "s3://${BUCKET}?region=${AWS_REGION}"

When initialising the stack for the first time, pass the secrets provider:

  pulumi stack init prod \\
    --secrets-provider="awskms://${KMS_ALIAS}?region=${AWS_REGION}"

(For an existing stack: pulumi stack change-secrets-provider with the same URL.)
EOF
