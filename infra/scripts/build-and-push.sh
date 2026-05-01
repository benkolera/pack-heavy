#!/usr/bin/env bash
#
# Build the app's ARM64 Docker image, push it to ECR, set the new tag
# in Pulumi config, and run `pulumi up` to roll the ECS service.
# Reads the repo URL from `pulumi stack output ecrRepositoryUrl` so
# this only works after the registry is provisioned.
#
# Usage:
#   ./infra/scripts/build-and-push.sh           # tag = short git SHA
#   ./infra/scripts/build-and-push.sh v0.1.0    # explicit tag
#
# Env overrides:
#   AWS_REGION  (default: ap-southeast-2)
#   STACK       (default: prod)
#   PLATFORM    (default: linux/arm64 — matches Fargate runtimePlatform)
#   SKIP_DEPLOY (set to any value to skip `pulumi config set` + `pulumi up`)

set -euo pipefail

AWS_REGION="${AWS_REGION:-ap-southeast-2}"
STACK="${STACK:-prod}"
PLATFORM="${PLATFORM:-linux/arm64}"

# Repo root = directory containing this script's parent (infra/scripts/)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INFRA_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd "${INFRA_DIR}/.." && pwd)

TAG="${1:-$(git -C "${REPO_ROOT}" rev-parse --short HEAD)}"

REPO_URL=$(pulumi -C "${INFRA_DIR}" stack output ecrRepositoryUrl --stack "${STACK}")
if [[ -z "${REPO_URL}" || "${REPO_URL}" == "null" ]]; then
  echo "✗ ecrRepositoryUrl is empty. Run \`pulumi up\` first." >&2
  exit 1
fi

REGISTRY="${REPO_URL%%/*}"

echo "→ Tag:      ${TAG}"
echo "→ Repo:     ${REPO_URL}"
echo "→ Platform: ${PLATFORM}"
echo

echo "→ Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "→ Building image"
docker buildx build \
  --platform "${PLATFORM}" \
  --tag "packheavy:${TAG}" \
  --tag "${REPO_URL}:${TAG}" \
  --load \
  "${REPO_ROOT}"

echo "→ Pushing"
docker push "${REPO_URL}:${TAG}"

if [[ -n "${SKIP_DEPLOY:-}" ]]; then
  cat <<EOF

Done (deploy skipped). To roll out manually:

  pulumi -C ${INFRA_DIR} config set packheavy:imageTag ${TAG}
  pulumi -C ${INFRA_DIR} up
EOF
  exit 0
fi

echo "→ Setting packheavy:imageTag=${TAG}"
pulumi -C "${INFRA_DIR}" config set packheavy:imageTag "${TAG}" --stack "${STACK}"

echo "→ pulumi up"
pulumi -C "${INFRA_DIR}" up --stack "${STACK}" --yes
