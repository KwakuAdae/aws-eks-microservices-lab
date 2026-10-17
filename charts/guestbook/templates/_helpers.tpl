{{- define "guestbook.name" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "guestbook.labels" -}}
app.kubernetes.io/part-of: {{ include "guestbook.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector labels for one component: include "guestbook.selector" (dict "ctx" . "component" "api") */}}
{{- define "guestbook.selector" -}}
app.kubernetes.io/name: {{ include "guestbook.name" .ctx }}-{{ .component }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "guestbook.image" -}}
{{- if not .image.repository -}}
{{- fail (printf "%s.image.repository is required (your ECR repository URI)" .component) -}}
{{- end -}}
{{ .image.repository }}:{{ .image.tag }}
{{- end -}}
