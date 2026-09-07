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
{{- if .Values.labels }}
{{- toYaml .Values.labels }}
{{- else -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pgdog
{{- end }}
{{- end }}

{{/*
Selector labels for pgdog
*/}}
{{- define "pgdog.selectorLabels" -}}
{{- if .Values.selectorLabels }}
{{- toYaml .Values.selectorLabels }}
{{- else -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pgdog
{{- end }}
{{- end }}

{{/*
Common labels for prometheus-collector
*/}}
{{- define "pgdog.prometheusCollector.labels" -}}
{{- if .Values.prometheusCollector.labels }}
{{- toYaml .Values.prometheusCollector.labels }}
{{- else -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: prometheus-collector
{{- end }}
{{- end }}

{{/*
Selector labels for prometheus-collector
*/}}
{{- define "pgdog.prometheusCollector.selectorLabels" -}}
{{- if .Values.prometheusCollector.selectorLabels }}
{{- toYaml .Values.prometheusCollector.selectorLabels }}
{{- else -}}
app.kubernetes.io/name: {{ include "pgdog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: prometheus-collector
{{- end }}
{{- end }}

{{/*
Render an integer value safely.
YAML parses large integers (>= 10M) as float64, which Helm renders
as scientific notation (e.g. 8.64e+07). TOML rejects this.
- String inputs (defaults like "30_000", user strings): pass through as-is
- Numeric inputs (float64 from YAML): convert via int64
*/}}
{{- define "pgdog.intval" -}}
{{- if kindIs "string" . -}}{{ . }}{{- else -}}{{ int64 . }}{{- end -}}
{{- end -}}

{{/*
Render a single FlexibleType value (integer | uuid | string) as a TOML literal.
pgdog's FlexibleType accepts integers, UUIDs and strings. Numbers must render as
bare TOML integers (see pgdog.intval); everything else is a string and must be
quoted to be valid TOML.
- Numeric inputs (float64 from YAML): render bare via int64
- String inputs (UUIDs, arbitrary keys, quoted numbers): render quoted
*/}}
{{- define "pgdog.flexval" -}}
{{- if kindIs "string" . -}}{{ . | quote }}{{- else -}}{{ int64 . }}{{- end -}}
{{- end -}}

{{/*
Render a list of FlexibleType values as a TOML array literal.
Each element is rendered via pgdog.flexval (numbers bare, strings quoted),
comma-separated and wrapped in brackets, e.g. [1, 2, 3] or ["a", "b"].
Call as: include "pgdog.flexlist" .values
*/}}
{{- define "pgdog.flexlist" -}}
[{{- range $i, $v := . }}{{ if $i }}, {{ end }}{{ include "pgdog.flexval" $v }}{{- end }}]
{{- end -}}

{{/*
Render the workers setting.
"auto" derives it from container CPU resources: 2 workers per vCPU
(pgdog's recommendation), rounded up. Uses resources.limits.cpu, or
resources.requests.cpu when noCpuLimits is true (no CPU limit applies then).
Any other value renders as-is via pgdog.intval.
*/}}
{{- define "pgdog.workers" -}}
{{- if eq (toString .Values.workers) "auto" -}}
{{- $res := .Values.resources | default dict -}}
{{- $limits := $res.limits | default dict -}}
{{- $requests := $res.requests | default dict -}}
{{- $cpu := ternary $requests.cpu ($limits.cpu | default $requests.cpu) (.Values.noCpuLimits | default false) -}}
{{- if not $cpu -}}
{{- fail "workers: auto requires resources.limits.cpu (or resources.requests.cpu when noCpuLimits is true)" -}}
{{- end -}}
{{- $cpu = toString $cpu -}}
{{- $cores := 0.0 -}}
{{- if hasSuffix "m" $cpu -}}
{{- $cores = divf (float64 (trimSuffix "m" $cpu)) 1000 -}}
{{- else -}}
{{- $cores = float64 $cpu -}}
{{- end -}}
{{- max 1 (int (ceil (mulf 2 $cores))) -}}
{{- else -}}
{{- include "pgdog.intval" .Values.workers -}}
{{- end -}}
{{- end -}}

{{/*
Render a resources block, omitting CPU limits when noCpuLimits is true.
Call as: include "pgdog.resources" (dict "resources" .Values.resources "noCpuLimits" .Values.noCpuLimits)
*/}}
{{- define "pgdog.resources" -}}
{{- $res := .resources -}}
{{- if $res -}}
resources:
  {{- if $res.requests }}
  requests:
    {{- toYaml $res.requests | nindent 4 }}
  {{- end }}
  {{- $limits := $res.limits }}
  {{- if and .noCpuLimits $limits }}
  {{- $limits = omit $limits "cpu" }}
  {{- end }}
  {{- if $limits }}
  limits:
    {{- toYaml $limits | nindent 4 }}
  {{- end }}
{{- end }}
{{- end -}}
