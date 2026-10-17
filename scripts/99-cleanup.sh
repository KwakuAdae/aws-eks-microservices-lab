#!/usr/bin/env bash
# Delete everything, in an order that avoids orphaned load balancers.
source "$(dirname "$0")/config.sh"
set +e

step "1) Uninstall the app (the ALB is deleted when its Ingress goes away)"
helm uninstall "$RELEASE" -n "$NAMESPACE" --wait
echo "   Waiting 60s for the controller to delete the ALB..."
sleep 60
kubectl delete namespace "$NAMESPACE" --wait=true

step "2) Uninstall the AWS Load Balancer Controller"
helm uninstall aws-load-balancer-controller -n kube-system

step "3) Delete the Pod Identity association, IAM policy and DynamoDB table"
eksctl delete podidentityassociation --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace "$NAMESPACE" --service-account-name "$API_SA"
aws iam delete-policy --policy-arn "$POLICY_ARN"
aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$AWS_REGION" >/dev/null

step "4) Delete the ECR repositories"
for repo in guestbook-api guestbook-frontend; do
  aws ecr delete-repository --repository-name "$repo" --force --region "$AWS_REGION" >/dev/null
done

step "5) Delete the cluster (~10-15 minutes)"
eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait

echo ""
echo "✅ Cleanup complete. Double-check EC2 → Load Balancers and CloudFormation for leftovers."
