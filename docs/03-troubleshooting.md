# Troubleshooting

Start here:

```bash
kubectl get pods,svc,ingress -n guestbook
kubectl describe pod -n guestbook -l app.kubernetes.io/component=api   # Events at the bottom
kubectl logs -n guestbook deploy/guestbook-api --tail=50
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50
```

## Ingress / ALB

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Ingress `ADDRESS` stays empty | Load Balancer Controller not running or lacks permissions | `kubectl get deploy -n kube-system aws-load-balancer-controller`; check its logs for `AccessDenied`; confirm `eksctl get podidentityassociation` lists `kube-system/aws-load-balancer-controller` |
| Controller logs `couldn't auto-discover subnets` | Subnets missing the ELB tags | eksctl-created VPCs are tagged. For your own VPC, tag public subnets `kubernetes.io/role/elb=1` |
| ALB returns **502/503** | Targets unhealthy | **EC2 → Target Groups → Targets**. The API group must check `/api/health`, the frontend `/healthz` (set by Service annotations) |
| Site loads but the API panel says "API unavailable" | `/api` rule missing or API pods not ready | `kubectl describe ingress guestbook -n guestbook`; check API pod readiness |
| URL doesn't resolve yet | New ALB DNS still propagating | Wait 1–2 minutes |

## Pods

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ImagePullBackOff` | Wrong ECR URI/tag, or the image wasn't pushed | `aws ecr list-images --repository-name guestbook-api`; re-run `02-build-push.sh` |
| `CrashLoopBackOff` with `exec format error` | Image built for ARM on Apple Silicon | The script builds `--platform linux/amd64`. Rebuild and push |
| `CreateContainerConfigError: runAsNonRoot` | Image runs as root | Use the provided Dockerfiles (UID 10001 / 101) |
| Pods `Pending`, `Insufficient cpu` | Nodes are full (prod values ask for more) | Scale the node group: `eksctl scale nodegroup --cluster eks-guestbook-lab --name app-nodes --nodes 3` |
| HPA shows `<unknown>/60%` | metrics-server not ready | `kubectl get deploy metrics-server -n kube-system`; wait a minute after install |

## AWS access (Pod Identity)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Info panel: `AWS identity: unavailable (NoCredentialsError)` | No association for this namespace/service account, or pods started before it existed | `eksctl get podidentityassociation --cluster eks-guestbook-lab`; then `kubectl rollout restart deploy/guestbook-api -n guestbook` |
| Identity shows the **node** role | Pod Identity agent add-on missing | `kubectl get ds -n kube-system eks-pod-identity-agent`; add the `eks-pod-identity-agent` add-on |
| `Could not save message: ClientError` | Policy doesn't cover the table (name or region mismatch) | Compare `TABLE_NAME` in `scripts/config.sh` with the policy; `aws iam get-policy-version ...` |
| `Could not read messages: ResourceNotFoundException` | Table missing or in another region | Re-run `03-setup-aws-access.sh`; check `awsRegion` in the chart values |

## Helm

| Symptom | Fix |
|---------|-----|
| `api.image.repository is required` | Pass `--set api.image.repository=...` (the deploy script does this) |
| `another operation (install/upgrade/rollback) is in progress` | `helm history guestbook -n guestbook`, then `helm rollback guestbook <last-good> -n guestbook` |
| `--wait` times out | Pods aren't becoming ready; see the Pods section |

## Cleanup

| Symptom | Fix |
|---------|-----|
| `eksctl delete cluster` fails deleting the VPC stack | An ALB or its security group still exists. Delete leftover `k8s-guestboo-*` load balancers and security groups in the EC2 console, then retry |
