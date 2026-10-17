#!/usr/bin/env bash
# Step 5: Generate CPU load on the API from inside the cluster and watch the HPA scale it.
source "$(dirname "$0")/config.sh"
SECONDS_TO_RUN="${1:-180}"

step "Starting 4 load generators for ${SECONDS_TO_RUN}s"
for i in 1 2 3 4; do
  kubectl run "load-${i}" -n "$NAMESPACE" --image=busybox:1.36 --restart=Never --quiet -- \
    /bin/sh -c "end=\$((\$(date +%s)+${SECONDS_TO_RUN})); while [ \$(date +%s) -lt \$end ]; do wget -q -O- http://${RELEASE}-api:8080/api/info >/dev/null; done" \
    >/dev/null 2>&1 || true
done

echo "Watching the API HPA (Ctrl+C to stop watching; load stops by itself)..."
kubectl get hpa "${RELEASE}-api" -n "$NAMESPACE" -w &
WATCH=$!
sleep "$SECONDS_TO_RUN"
kill $WATCH 2>/dev/null || true
kubectl delete pod -n "$NAMESPACE" load-1 load-2 load-3 load-4 --ignore-not-found >/dev/null
echo "Load stopped. The HPA scales back down after ~5 minutes of low CPU."
