#!/usr/bin/env bash
# Step 1: EKS cluster, managed node group, add-ons (incl. Pod Identity agent) and the
# Pod Identity role for the AWS Load Balancer Controller. Takes ~20 minutes.
source "$(dirname "$0")/config.sh"

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Cluster ${CLUSTER_NAME} already exists, skipping."
else
  step "Creating cluster ${CLUSTER_NAME} in ${AWS_REGION} (grab a coffee ☕)"
  sed -e "s/^  name: eks-guestbook-lab/  name: ${CLUSTER_NAME}/" \
      -e "s/^  region: us-east-1/  region: ${AWS_REGION}/" \
      "${ROOT_DIR}/eks/cluster.yaml" | eksctl create cluster -f -
fi

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl get nodes -o wide
