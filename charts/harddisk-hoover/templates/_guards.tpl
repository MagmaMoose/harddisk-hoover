{{/*
Preflight checks, for values that would otherwise render a CronJob that cannot work.
`fail` turns each into a readable `helm template` error instead.

Included once from NOTES.txt so they run on template, install and upgrade.
*/}}
{{- define "harddisk-hoover.guards" -}}

{{- if not (include "harddisk-hoover.steps" .) }}
{{- fail "steps: every step is off, so the cleanup would do nothing. Turn one on, or set suspend: true." }}
{{- end }}

{{- $p := int .Values.threshold.percent }}
{{- if or (lt $p 0) (gt $p 100) }}
{{- fail (printf "threshold.percent is %d; it is a percentage, from 0 (clean every node) to 100." $p) }}
{{- end }}

{{- if not (hasPrefix "/" .Values.threshold.path) }}
{{- fail (printf "threshold.path %q must be an absolute path on the node." .Values.threshold.path) }}
{{- end }}

{{- range .Values.limits.logDirs }}
{{- if not (hasPrefix "/" .) }}
{{- fail (printf "limits.logDirs: %q must be an absolute path on the node." .) }}
{{- end }}
{{- end }}

{{- if lt (int .Values.limits.exitedContainerMinAgeHours) 1 }}
{{- fail "limits.exitedContainerMinAgeHours must be at least 1, so a container that has just crashed keeps its logs for kubectl logs --previous." }}
{{- end }}

{{- if lt (int .Values.nodes.podTimeoutSeconds) 60 }}
{{- fail "nodes.podTimeoutSeconds must be at least 60: pulling the image alone can take longer than that." }}
{{- end }}

{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.apiServer) }}
{{- fail "networkPolicy.apiServer is empty, so the controller could not reach the Kubernetes API. List where it lives, or turn networkPolicy off." }}
{{- end }}

{{- end }}
