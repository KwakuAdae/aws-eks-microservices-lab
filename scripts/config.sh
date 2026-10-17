#!/usr/bin/env bash
# Shared lab settings. Override any value by exporting it before running a script.
set -euo pipefail
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""
export CLUSTER_NAME="${CLUSTER_NAME:-eks-guestbook-lab}"
export NAMESPACE="${NAMESPACE:-guestbook}"
export RELEASE="${RELEASE:-guestbook}"
export TABLE_NAME="${TABLE_NAME:-eks-guestbook-lab-messages}"
export POLICY_NAME="${POLICY_NAME:-eks-guestbook-lab-dynamodb}"
export API_SA="guestbook-api"
export IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step() { echo ""; echo "▶ $*"; }
