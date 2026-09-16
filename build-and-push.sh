#!/bin/bash
set -euo pipefail

# ============================================================
# Build, tag, and push all microservice images to AWS ECR
# ============================================================
# Usage:
#   ./build-and-push.sh <AWS_ACCOUNT_ID> [AWS_REGION]
#
# Example:
#   ./build-and-push.sh 123456789012 us-east-1
# ============================================================

AWS_ACCOUNT_ID="${1:?Usage: $0 <AWS_ACCOUNT_ID> [AWS_REGION]}"
AWS_REGION="${2:-us-east-1}"
ECR_REPO="online-boutique"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"
TAG="latest"

SERVICES=(
  "adservice"
  "cartservice"
  "checkoutservice"
  "currencyservice"
  "emailservice"
  "frontend"
  "paymentservice"
  "productcatalogservice"
  "recommendationservice"
  "shippingservice"
)

echo "==> Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Ensuring ECR repository exists..."
aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" 2>/dev/null || \
  aws ecr create-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}"

echo "==> Building all service images..."
docker compose build

echo "==> Tagging and pushing images to ECR..."
for SERVICE in "${SERVICES[@]}"; do
  echo "--- ${SERVICE} ---"

  # Get the image ID that docker compose built for this service
  IMAGE_ID=$(docker compose images -q "${SERVICE}")

  if [ -z "${IMAGE_ID}" ]; then
    echo "  WARNING: No image found for ${SERVICE}, skipping."
    continue
  fi

  REMOTE_TAG="${ECR_URI}:${SERVICE}-${TAG}"
  docker tag "${IMAGE_ID}" "${REMOTE_TAG}"
  docker push "${REMOTE_TAG}"
  echo "  Pushed: ${REMOTE_TAG}"
done

echo ""
echo "==> All images pushed successfully!"
echo ""
echo "Services pushed:"
for SERVICE in "${SERVICES[@]}"; do
  echo "  - ${ECR_URI}:${SERVICE}-${TAG}"
done