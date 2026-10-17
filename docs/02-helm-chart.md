# A Tour of the Guestbook Helm Chart

```
charts/guestbook/
├── Chart.yaml              # name, chart version (0.1.0), app version (1.0.0)
├── values.yaml             # defaults (dev)
├── values-prod.yaml        # overrides for production
└── templates/
    ├── _helpers.tpl        # reusable snippets: names, labels, selectors, image check
    ├── api-serviceaccount.yaml
    ├── api-configmap.yaml
    ├── api-deployment.yaml
    ├── frontend-deployment.yaml
    ├── services.yaml       # loops over api + frontend
    ├── ingress.yaml        # ALB with /api and / rules
    ├── autoscaling.yaml    # HPA per component (loop)
    ├── pdb.yaml            # PodDisruptionBudget per component (loop)
    └── NOTES.txt           # printed after install
```

## Values: one chart, many environments

Precedence (last wins): `values.yaml` → `-f values-prod.yaml` → `--set key=value`.

```bash
helm template guestbook charts/guestbook \
  -f charts/guestbook/values-prod.yaml \
  --set api.image.repository=x --set frontend.image.repository=y \
  --set api.greeting="Hi"
```

## Techniques used in the templates

### Helpers (`_helpers.tpl`)

```yaml
{{- define "guestbook.selector" -}}
app.kubernetes.io/name: {{ include "guestbook.name" .ctx }}-{{ .component }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
```

Called with a `dict` so one helper serves both components:
`{{ include "guestbook.selector" (dict "ctx" . "component" "api") | nindent 6 }}`.

### Required values with `fail`

```yaml
{{- if not .image.repository -}}
{{- fail (printf "%s.image.repository is required (your ECR repository URI)" .component) -}}
{{- end -}}
```

Forget `--set api.image.repository=...` and Helm stops with a clear message instead of
deploying a broken image reference.

### Loops with `range`

`services.yaml`, `autoscaling.yaml` and `pdb.yaml` loop over `list "api" "frontend"` and look up
each component's values with `index $.Values $component`. Inside `range`, use `$` for the root context.

### Roll pods when config changes

```yaml
annotations:
  checksum/config: {{ include (print $.Template.BasePath "/api-configmap.yaml") . | sha256sum }}
```

A ConfigMap change alters the checksum. That changes the pod template, which triggers a rolling update.

### Replicas vs HPA

When autoscaling is enabled the Deployment omits `replicas`. Otherwise every `helm upgrade`
would reset the replica count and fight the HPA.

## Production-minded settings

| Setting | Why |
|---------|-----|
| `runAsNonRoot`, `allowPrivilegeEscalation: false`, `drop: ["ALL"]`, `seccompProfile: RuntimeDefault` | Containers run with minimal privileges |
| `readOnlyRootFilesystem: true` (API) | The API can't modify its own filesystem |
| Readiness and liveness probes | Traffic only goes to ready pods; hung pods restart |
| `maxUnavailable: 0` | Rolling updates never drop below the desired count |
| `topologySpreadConstraints` | Spread replicas across nodes |
| PodDisruptionBudget | Node drains/upgrades keep at least N pods running |
| ClusterIP Services + one Ingress | One public entry point (the ALB), internal services stay private |
| Per-Service `alb.ingress.kubernetes.io/healthcheck-path` | Each ALB target group checks the right health endpoint |

## Useful Helm commands

```bash
helm lint charts/guestbook --set api.image.repository=x --set frontend.image.repository=y
helm list -n guestbook
helm get values guestbook -n guestbook          # values used by the current release
helm get manifest guestbook -n guestbook        # what was actually applied
helm history guestbook -n guestbook
helm rollback guestbook <revision> -n guestbook
helm uninstall guestbook -n guestbook
```
