#!/usr/bin/env bash
# Step 2: Build both images and push them to two ECR repositories.
source "$(dirname "$0")/config.sh"

step "Logging Docker in to ECR"
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$REGISTRY"

for svc in api frontend; do
  repo="guestbook-${svc}"
  step "${repo}:${IMAGE_TAG}"
  aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" \
      --image-scanning-configuration scanOnPush=true >/dev/null
  docker build --platform linux/amd64 -t "${REGISTRY}/${repo}:${IMAGE_TAG}" "${ROOT_DIR}/services/${svc}"
  docker push "${REGISTRY}/${repo}:${IMAGE_TAG}"
done
