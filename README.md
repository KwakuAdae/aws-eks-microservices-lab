# Lab: Microservices on Amazon EKS with Helm, ALB Ingress and Pod Identity

A hands-on lab that runs a **two-service application** on **Amazon EKS**. A **frontend**
(nginx) and an **API** (Python) are packaged as one **Helm chart** and exposed through a single
**Application Load Balancer** created from a Kubernetes **Ingress**. The API stores data in
**DynamoDB** using **EKS Pod Identity**, so there are no AWS access keys anywhere.

> This lab builds on [Deploy a Website to Amazon EKS](https://github.com/KwakuAdae/kwakuadae-aws-eks-website-lab),
> which covers one container, plain manifests and a `LoadBalancer` Service. Here you go further:
> multiple services, Helm, path-based routing, AWS permissions for pods, and production
> settings such as PodDisruptionBudgets and topology spread.

```
                                   ┌──────────────────────── Amazon EKS cluster ────────────────────────────┐
                                   │  namespace: guestbook                                                    │
 ┌─────────┐  HTTP  ┌───────────┐  │   ┌──────────────────┐        ┌──────────────────────────────┐         │
 │ Browser │ ─────▶ │    ALB    │──┼─▶ │ Service frontend │ ─────▶ │ Deployment frontend (nginx)  │ 2-4 pods│
 └─────────┘        │ (created  │  │   └──────────────────┘   /    └──────────────────────────────┘         │
                    │  from the │──┼─▶ ┌──────────────────┐ /api/* ┌──────────────────────────────┐         │
                    │  Ingress) │  │   │ Service api      │ ─────▶ │ Deployment api (Python)      │ 2-6 pods│
                    └───────────┘  │   └──────────────────┘        │  serviceAccount: guestbook-api│        │
                                   │                               └───────────────┬──────────────┘         │
                                   │  kube-system: AWS Load Balancer Controller    │ credentials from       │
                                   │               EKS Pod Identity Agent ─────────┘ EKS Pod Identity        │
                                   └────────────────────────────────────────────────┼───────────────────────┘
                                                                                    ▼
                                         IAM role (Query + PutItem on one table) ──▶ DynamoDB: guestbook messages
```

## What you will learn

| Area | Topics |
|------|--------|
| **EKS** | eksctl config files, managed node groups in private subnets, EKS add-ons |
| **AWS access from pods** | **EKS Pod Identity**: associations, the Pod Identity Agent add-on, least-privilege IAM, verifying with `sts get-caller-identity` |
| **Ingress** | AWS Load Balancer Controller, `IngressClass alb`, path-based routing to two services, `target-type: ip`, per-service health checks |
| **Helm** | Writing a chart: templates, helpers, `values.yaml` vs `values-prod.yaml`, `--set`, `fail` for required values, `upgrade --install`, `rollback`, `history` |
| **Kubernetes** | Deployments, ClusterIP Services, ConfigMaps (with checksum-triggered rollouts), ServiceAccounts, HPAs, PodDisruptionBudgets, topology spread constraints, probes, security contexts |
| **Containers** | Two non-root images, nginx config templates, local testing with Docker Compose + DynamoDB Local |

## Project structure

```
aws-eks-microservices-lab/
├── services/
│   ├── api/                    # Python API (stdlib HTTP server + boto3), Dockerfile
│   └── frontend/               # nginx + HTML/JS guestbook UI, Dockerfile, nginx template
├── charts/guestbook/           # Helm chart for both services
│   ├── Chart.yaml
│   ├── values.yaml             # dev defaults
│   ├── values-prod.yaml        # production overrides
│   └── templates/              # deployments, services, ingress, HPAs, PDBs, configmap, SA
├── eks/cluster.yaml            # eksctl: cluster, node group, add-ons, LB controller identity
├── iam/guestbook-dynamodb-policy.json
├── scripts/
│   ├── 01-create-cluster.sh    # eksctl create cluster (~20 min)
│   ├── 02-build-push.sh        # build + push both images to ECR
│   ├── 03-setup-aws-access.sh  # DynamoDB, IAM policy, Pod Identity, LB controller
│   ├── 04-deploy-app.sh        # helm upgrade --install, prints the ALB URL
│   ├── 05-load-test.sh         # generate load, watch the HPA scale
│   └── 99-cleanup.sh           # delete everything in a safe order
├── tests/test_api.py           # 12 API tests (moto, no AWS needed)
├── docker-compose.yml          # run the whole app locally
└── docs/
    ├── 01-pod-identity.md
    ├── 02-helm-chart.md
    └── 03-troubleshooting.md
```

## Prerequisites

| Tool | Check | Install |
|------|-------|---------|
| AWS account | — | ⚠️ EKS is **not** free tier, see [Cost](#cost) |
| AWS CLI v2 | `aws --version` | then `aws configure` |
| eksctl ≥ 0.190 | `eksctl version` | `brew install eksctl` |
| kubectl | `kubectl version --client` | `brew install kubectl` |
| Helm 3 | `helm version` | `brew install helm` |
| Docker | `docker --version` | Docker Desktop |
| Python 3.12 *(tests)* | `python3 --version` | |

Your IAM identity needs permissions for EKS, EC2, IAM, CloudFormation, ECR, DynamoDB and
Elastic Load Balancing. `AdministratorAccess` is simplest for a personal lab account.

---

## Quick start

```bash
git clone https://github.com/KwakuAdae/aws-eks-microservices-lab.git
cd aws-eks-microservices-lab

./scripts/01-create-cluster.sh      # ~20 min
./scripts/02-build-push.sh
./scripts/03-setup-aws-access.sh
./scripts/04-deploy-app.sh          # prints http://<alb-address>
./scripts/99-cleanup.sh             # IMPORTANT when you're done
```

---

## Step 1: Run it locally first (free)

```bash
pip install -r requirements-dev.txt && pytest -v     # 12 API tests

docker compose up --build                            # frontend + api + DynamoDB Local
# open http://localhost:8080 and sign the guestbook
docker compose down -v
```

The compose file starts **DynamoDB Local**, creates the table, then runs both services. The info
panel shows `AWS identity: unavailable` locally. On EKS it will show the IAM role that Pod
Identity gave the pod.

## Step 2: Create the cluster

Read [`eks/cluster.yaml`](eks/cluster.yaml) first:

- **Managed node group** of 2 × `t3.medium` in **private subnets**. Only the ALB is public.
- **Add-ons**: `vpc-cni`, `coredns`, `kube-proxy`, `metrics-server` (for HPAs) and
  **`eks-pod-identity-agent`**.
- **`iam.podIdentityAssociations`**: eksctl creates an IAM role with AWS's recommended
  Load Balancer Controller policy, plus the `aws-load-balancer-controller` service account,
  and links them.

```bash
eksctl create cluster -f eks/cluster.yaml     # or ./scripts/01-create-cluster.sh
kubectl get nodes
kubectl get pods -n kube-system               # look for eks-pod-identity-agent-* on each node
```

## Step 3: Build and push the images

```bash
./scripts/02-build-push.sh
```

This creates two ECR repositories, `guestbook-api` and `guestbook-frontend`, and pushes
`:1.0.0` to each. Both images run as **non-root** users.

## Step 4: Give the API access to DynamoDB with Pod Identity

```bash
./scripts/03-setup-aws-access.sh
```

What it does, and why:

1. **Creates the table**: partition key `pk`, sort key `created`, so messages come back newest first.
2. **Creates an IAM policy** allowing only `dynamodb:Query` and `dynamodb:PutItem` on that one
   table ([`iam/guestbook-dynamodb-policy.json`](iam/guestbook-dynamodb-policy.json)).
3. **Creates a Pod Identity association**:

   ```bash
   eksctl create podidentityassociation --cluster eks-guestbook-lab \
     --namespace guestbook --service-account-name guestbook-api \
     --permission-policy-arns arn:aws:iam::<account>:policy/eks-guestbook-lab-dynamodb
   ```

   Any pod in namespace `guestbook` that uses service account `guestbook-api` now receives
   temporary credentials for that role. The AWS SDK finds them automatically.

4. **Installs the AWS Load Balancer Controller** with Helm. It watches Ingress objects and
   creates ALBs for them.

More detail: [docs/01-pod-identity.md](docs/01-pod-identity.md).

## Step 5: Deploy the app with Helm

```bash
./scripts/04-deploy-app.sh
```

which runs:

```bash
helm upgrade --install guestbook charts/guestbook \
  --namespace guestbook --create-namespace \
  --set api.image.repository=<account>.dkr.ecr.us-east-1.amazonaws.com/guestbook-api \
  --set frontend.image.repository=<account>.dkr.ecr.us-east-1.amazonaws.com/guestbook-frontend \
  --set api.tableName=eks-guestbook-lab-messages --wait
```

Preview what Helm will create at any time:

```bash
helm template guestbook charts/guestbook --set api.image.repository=x --set frontend.image.repository=y
```

The chart creates **11 Kubernetes objects**: 2 Deployments, 2 Services, 1 Ingress, 2 HPAs, 2
PodDisruptionBudgets, 1 ConfigMap and 1 ServiceAccount. A tour of the chart is in
[docs/02-helm-chart.md](docs/02-helm-chart.md).

## Step 6: Open the app

```bash
kubectl get ingress guestbook -n guestbook
# NAME        CLASS   HOSTS   ADDRESS                                              PORTS
# guestbook   alb     *       k8s-guestboo-guestboo-abc123.us-east-1.elb.amazonaws.com   80
```

Open `http://<ADDRESS>`. The info panel shows:

- **API pod / Node**: refresh to see different pods and nodes answer
- **AWS identity**: something like `arn:aws:sts::<account>:assumed-role/eksctl-eks-guestbook-lab-podidentityrole-.../...`.
  That's **Pod Identity** working.

Sign the guestbook, then check the data landed in DynamoDB:

```bash
aws dynamodb scan --table-name eks-guestbook-lab-messages --query 'Items[].[name.S,message.S]' --output table
```

**Path-based routing**: the ALB sends `/api/*` straight to the API service and everything else
to the frontend. Look at the listener rules in **EC2 → Load Balancers → Listeners → Rules**.

## Step 7: Prove least privilege

```bash
kubectl exec -n guestbook deploy/guestbook-api -- python -c "
import boto3
print(boto3.client('sts').get_caller_identity()['Arn'])
try:
    boto3.client('s3').list_buckets()
except Exception as e:
    print('S3 denied as expected:', type(e).__name__)
"
```

The pod can read and write its own table and nothing else.

## Step 8: Change config and upgrade with Helm

```bash
./scripts/04-deploy-app.sh --set api.greeting="Hello from a Helm upgrade!"
helm history guestbook -n guestbook
```

The API pods roll automatically: the Deployment carries a `checksum/config` annotation, so
any ConfigMap change creates new pods. Refresh the page to see the new greeting.

Undo it:

```bash
helm rollback guestbook 1 -n guestbook
```

## Step 9: Production values

```bash
./scripts/04-deploy-app.sh -f charts/guestbook/values-prod.yaml
kubectl get hpa,pdb -n guestbook
```

[`values-prod.yaml`](charts/guestbook/values-prod.yaml) raises replicas and resources, and sets
`minAvailable: 2` on the PodDisruptionBudgets. The same chart serves every environment.

## Step 10: Autoscaling

```bash
./scripts/05-load-test.sh 180
# NAME            REFERENCE                  TARGETS        MINPODS   MAXPODS   REPLICAS
# guestbook-api   Deployment/guestbook-api   cpu: 12%/60%   2         6         2
# guestbook-api   Deployment/guestbook-api   cpu: 145%/60%  2         6         2
# guestbook-api   Deployment/guestbook-api   cpu: 98%/60%   2         6         5
```

## Step 11: Resilience

```bash
# Self-healing: delete a pod, a replacement starts immediately
kubectl delete pod -n guestbook -l app.kubernetes.io/component=api --wait=false | head -1
kubectl get pods -n guestbook -w

# PodDisruptionBudget: draining a node never takes all API pods down at once
kubectl get nodes
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node-name>
```

## Step 12: Clean up

```bash
./scripts/99-cleanup.sh
```

The order matters: the app is uninstalled **first**, so the Load Balancer Controller deletes
the ALB before the cluster disappears. Otherwise the ALB is orphaned and blocks VPC deletion.

---

## Cost

| Resource | Approx. cost (us-east-1) |
|----------|--------------------------|
| EKS control plane | $0.10 / hour |
| 2 × t3.medium nodes | ~$0.083 / hour |
| NAT gateway (private nodes) | ~$0.045 / hour + data |
| Application Load Balancer | ~$0.0225 / hour + LCUs |
| DynamoDB on-demand, ECR | pennies |

**About $0.25–0.30 per hour.** Run the cleanup script when you finish.

## Going further

- **HTTPS**: request an ACM certificate and add `alb.ingress.kubernetes.io/certificate-arn`
- **ExternalDNS** to create a Route 53 record for the ALB automatically
- **Karpenter** for node autoscaling
- **Argo CD** to deploy the Helm chart with GitOps
- **NetworkPolicies** (enable network policy support in the VPC CNI) so only the frontend can call the API
- Package and publish the chart to **ECR as an OCI artifact**: `helm push`
- Sister labs: [EKS website](https://github.com/KwakuAdae/kwakuadae-aws-eks-website-lab) ·
  [ECS Fargate](https://github.com/KwakuAdae/aws-ecr-ecs-fargate-lab) ·
  [API Gateway + SAM](https://github.com/KwakuAdae/aws-api-gateway-sam-lab) ·
  [CloudWatch Logs + Terraform](https://github.com/KwakuAdae/aws-cloudwatch-logs-terraform-lab)

## Troubleshooting

See [docs/03-troubleshooting.md](docs/03-troubleshooting.md).

## Author

**Kwaku Adae**: [github.com/KwakuAdae](https://github.com/KwakuAdae)

Feedback and reviews are welcome. Open an issue or a pull request!
