#!/usr/bin/env bash
# Step 3: Everything the app needs from AWS:
#   a) DynamoDB table
#   b) IAM policy that allows only Query/PutItem on that table
#   c) EKS Pod Identity association: service account guestbook-api → IAM role with that policy
#   d) AWS Load Balancer Controller (turns the Ingress into an ALB)
source "$(dirname "$0")/config.sh"

step "a) DynamoDB table ${TABLE_NAME} (pk = partition, created = sort key)"
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws dynamodb create-table --table-name "$TABLE_NAME" --region "$AWS_REGION" \
    --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=created,AttributeType=N \
    --key-schema AttributeName=pk,KeyType=HASH AttributeName=created,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$AWS_REGION"
fi

step "b) IAM policy ${POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  sed -e "s/REGION/${AWS_REGION}/" -e "s/ACCOUNT_ID/${AWS_ACCOUNT_ID}/" -e "s/TABLE_NAME/${TABLE_NAME}/" \
    "${ROOT_DIR}/iam/guestbook-dynamodb-policy.json" > /tmp/guestbook-policy.json
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document file:///tmp/guestbook-policy.json >/dev/null
fi

step "c) Pod Identity association: ${NAMESPACE}/${API_SA} → IAM role"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
if ! eksctl get podidentityassociation --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
     --namespace "$NAMESPACE" --service-account-name "$API_SA" 2>/dev/null | grep -q "$API_SA"; then
  eksctl create podidentityassociation --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace "$NAMESPACE" --service-account-name "$API_SA" \
    --permission-policy-arns "$POLICY_ARN"
fi
eksctl get podidentityassociation --cluster "$CLUSTER_NAME" --region "$AWS_REGION"

step "d) AWS Load Balancer Controller (Helm)"
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query cluster.resourcesVpcConfig.vpcId --output text)
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId="$VPC_ID" \
  --wait
kubectl get deployment -n kube-system aws-load-balancer-controller
