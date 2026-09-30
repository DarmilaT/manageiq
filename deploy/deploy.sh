#!/bin/bash
# deploy/deploy.sh  ->  installed on the server as /opt/manageiq/deploy.sh
# Usage: sudo /opt/manageiq/deploy.sh <image-tag>
# Called by GitHub Actions through SSM, or manually for a rollback.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/manageiq}"
cd "$APP_DIR"

TAG="${1:?Usage: deploy.sh <image-tag>}"

env_get() { grep -E "^$1=" .env | tail -1 | cut -d= -f2-; }
AWS_REGION="$(env_get AWS_REGION)"
ECR_REGISTRY="$(env_get ECR_REGISTRY)"
: "${AWS_REGION:?AWS_REGION missing in .env}"
: "${ECR_REGISTRY:?ECR_REGISTRY missing in .env}"

echo "==> Deploying image tag: $TAG"

echo "==> Logging in to ECR ($ECR_REGISTRY)"
aws ecr get-login-password --region "$AWS_REGION" |
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "==> Recording tag in .env (so manual 'docker compose' commands use it too)"
if grep -q '^IMAGE_TAG=' .env; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TAG}/" .env
else
  echo "IMAGE_TAG=${TAG}" >> .env
fi

echo "==> Pulling new images"
docker compose pull app worker

echo "==> Restarting services"
docker compose up -d

echo "==> Waiting for the app to become healthy (max 10 min)"
for _ in $(seq 1 60); do
  if curl -fsk -o /dev/null https://localhost/; then
    echo "==> Healthy. Deployed $TAG"
    docker image prune -f > /dev/null
    exit 0
  fi
  sleep 10
done

echo "!! App did not become healthy. Last app logs:"
docker compose logs --tail 100 app
exit 1