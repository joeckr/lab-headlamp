{{- define "lab-headlamp.name" -}}
{{- .Values.app.name | default .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "lab-headlamp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "lab-headlamp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "lab-headlamp.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "lab-headlamp.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.app.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "lab-headlamp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "lab-headlamp.name" .) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{- define "lab-headlamp.serviceName" -}}
{{- .Values.service.name | default (include "lab-headlamp.name" .) -}}
{{- end -}}

{{- define "lab-headlamp.oidcSecretName" -}}
{{- if .Values.oidc.existingSecret -}}
{{- .Values.oidc.existingSecret -}}
{{- else -}}
{{- printf "%s-oidc" (include "lab-headlamp.name" .) -}}
{{- end -}}
{{- end -}}

{{- define "lab-headlamp.pvcName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-plugins" (include "lab-headlamp.name" .) -}}
{{- end -}}
{{- end -}}
