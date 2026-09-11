{{/*
Expand the name of the chart.
*/}}
{{- define "web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "web.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "web.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "web.labels" -}}
{{ include "web.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{/*
Opentelemetry labels
*/}}
opentelemetry/service: {{ include "web.fullname" . }}
opentelemetry/version: {{ .Values.global.image.tag }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "web.selectorLabels" -}}
app.kubernetes.io/component: {{ include "web.name" . }}
app.kubernetes.io/name: {{ include "web.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}



{{- define "web.probes" }}
failureThreshold: {{ .failureThreshold }}
{{- if and (.path) (not .exec) }}
httpGet:
    path: {{ .path }}
    port: http
{{- else if .exec }}
exec:
    command: {{ .exec  }}
{{- end }}
initialDelaySeconds: {{ .initialDelaySeconds }}
periodSeconds: {{ .periodSeconds }}
timeoutSeconds: {{ .timeoutSeconds }}
{{- end }}