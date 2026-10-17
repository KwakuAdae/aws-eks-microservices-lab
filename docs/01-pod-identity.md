# EKS Pod Identity Explained

## The problem

The API pod needs to call DynamoDB. Options, from worst to best:

| Approach | Problem |
|----------|---------|
| Access keys in an env var or Secret | Long-lived keys that leak and never rotate |
| Node IAM role (instance profile) | **Every** pod on the node gets the same permissions |
| IRSA (IAM Roles for Service Accounts) | Works well, but needs an OIDC provider and a role trust policy per cluster |
| **EKS Pod Identity** | Per-service-account roles, no OIDC setup, one trust policy reusable across clusters |

## How it works

```
 ┌────────────── Pod (serviceAccount: guestbook-api) ──────────────┐
 │  boto3 sees AWS_CONTAINER_CREDENTIALS_FULL_URI                   │
 │  → GET http://169.254.170.23/v1/credentials (with a pod token)   │
 └───────────────────────────────┬─────────────────────────────────┘
                                 ▼
          eks-pod-identity-agent (DaemonSet on every node)
                                 │  "which role is mapped to guestbook/guestbook-api?"
                                 ▼
                    EKS Auth API: AssumeRoleForPodIdentity
                                 │
                                 ▼
          temporary credentials for the associated IAM role (auto-refreshed)
```

1. The **eks-pod-identity-agent** add-on runs on every node.
2. A **Pod Identity association** maps *(cluster, namespace, service account)* to an IAM role.
3. When a pod using that service account starts, EKS injects two environment variables:
   `AWS_CONTAINER_CREDENTIALS_FULL_URI` and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`.
4. Every recent AWS SDK reads those and fetches credentials from the agent. **No code changes needed.**

The role's trust policy trusts the service principal `pods.eks.amazonaws.com`:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "pods.eks.amazonaws.com" },
  "Action": ["sts:AssumeRole", "sts:TagSession"]
}
```

eksctl writes this for you when it creates the association.

## Inspect it

```bash
# All associations in the cluster
eksctl get podidentityassociation --cluster eks-guestbook-lab
aws eks list-pod-identity-associations --cluster-name eks-guestbook-lab

# The variables injected into the API pod
kubectl exec -n guestbook deploy/guestbook-api -- env | grep AWS_CONTAINER

# Who the pod is, as AWS sees it
kubectl exec -n guestbook deploy/guestbook-api -- \
  python -c "import boto3; print(boto3.client('sts').get_caller_identity()['Arn'])"
```

## Things to know

- Associations apply to **new** pods. If you create one after the pods started, restart them:
  `kubectl rollout restart deployment/guestbook-api -n guestbook`.
- The service account name and namespace must match **exactly**. This lab uses
  `guestbook/guestbook-api` (set in `values.yaml` → `api.serviceAccount.name`).
- Pod Identity works on EC2 nodes. For **Fargate** pods, use IRSA instead.
- Session tags (`eks-cluster-name`, `kubernetes-namespace`, `kubernetes-service-account`, ...) are
  added automatically, so one IAM role can be shared across clusters and scoped with ABAC conditions.
