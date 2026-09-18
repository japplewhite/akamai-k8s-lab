{{/*
Fully-qualified name: <release>-<chart>, unless the release name already contains the chart
name (avoids "hello-lab-hello-lab"). Same pattern `helm create` scaffolds, written by hand here
so the reasoning is understood rather than copy-pasted.
*/}}
{{- define "hello-lab.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "hello-lab.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
