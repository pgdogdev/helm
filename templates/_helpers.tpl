{{/*
Expand the name of the chart.
*/}}
{{- define "pgdog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pgdog.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "pgdog.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pgdog.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Common labels for pgdog
*/}}
{{- define "pgdog.labels" -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pgdog
{{- end }}

{{/*
Selector labels for pgdog
*/}}
{{- define "pgdog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pgdog
{{- end }}

{{/*
Common labels for gateway
*/}}
{{- define "pgdog.gateway.labels" -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: gateway
{{- end }}

{{/*
Selector labels for gateway
*/}}
{{- define "pgdog.gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: gateway
{{- end }}
