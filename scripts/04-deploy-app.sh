#!/usr/bin/env bash
# Step 4: Install (or upgrade) the guestbook Helm chart and print the ALB URL.
#   ./scripts/04-deploy-app.sh                                  # dev values
#   ./scripts/04-deploy-app.sh -f charts/guestbook/values-prod.yaml
source "$(dirname "$0")/config.sh"

step "helm upgrade --install ${RELEASE} (image tag ${IMAGE_TAG})"
helm upgrade --install "$RELEASE" "${ROOT_DIR}/charts/guestbook" \
  --namespace "$NAMESPACE" --create-namespace \
  --set awsRegion="$AWS_REGION" \
  --set api.tableName="$TABLE_NAME" \
  --set api.image.repository="${REGISTRY}/guestbook-api" \
  --set api.image.tag="$IMAGE_TAG" \
  --set frontend.image.repository="${REGISTRY}/guestbook-frontend" \
  --set frontend.image.tag="$IMAGE_TAG" \
  --wait --timeout 5m \
  "$@"

kubectl get pods,svc,ingress,hpa,pdb -n "$NAMESPACE"

step "Waiting for the ALB address (2-3 minutes the first time)"
for _ in $(seq 1 60); do
  ALB=$(kubectl get ingress "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  [[ -n "$ALB" ]] && break
  sleep 5
done
echo ""
echo "✅ Open http://${ALB}"
echo "   (new ALBs need another minute or two before DNS resolves and targets are healthy)"
