{{/* Nome base do release, truncado para caber em labels/DNS. */}}
{{- define "mural.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mural.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mural.labels" -}}
app.kubernetes.io/name: {{ include "mural.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "mural.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mural.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* DATABASE_URL montada a partir dos values de postgres. */}}
{{- define "mural.databaseUrl" -}}
{{- printf "postgres://%s:%s@%s-postgres:%v/%s?sslmode=disable" .Values.postgres.user .Values.postgres.password (include "mural.fullname" .) .Values.postgres.port .Values.postgres.database -}}
{{- end -}}
