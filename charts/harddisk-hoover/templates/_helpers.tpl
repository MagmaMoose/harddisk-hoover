{{/*
Name helpers, the standard Helm set.
*/}}
{{- define "harddisk-hoover.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "harddisk-hoover.fullname" -}}
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

{{- define "harddisk-hoover.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "harddisk-hoover.labels" -}}
helm.sh/chart: {{ include "harddisk-hoover.chart" . }}
{{ include "harddisk-hoover.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "harddisk-hoover.selectorLabels" -}}
app.kubernetes.io/name: {{ include "harddisk-hoover.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "harddisk-hoover.controllerServiceAccount" -}}
{{- include "harddisk-hoover.fullname" . }}
{{- end }}

{{- define "harddisk-hoover.cleanupServiceAccount" -}}
{{- printf "%s-cleanup" (include "harddisk-hoover.fullname" . | trunc 55 | trimSuffix "-") }}
{{- end }}

{{/*
Cluster-scoped names carry the namespace, so two releases of the same name in different
namespaces do not fight over one ClusterRole.
*/}}
{{- define "harddisk-hoover.clusterName" -}}
{{- printf "%s-%s" .Release.Namespace (include "harddisk-hoover.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Image reference. An empty image.tag falls back to .Chart.AppVersion, and a digest,
when given, pins the image whatever the tag later points at.
*/}}
{{- define "harddisk-hoover.image" -}}
{{- $ref := printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- if .Values.image.digest }}
{{- $ref = printf "%s@%s" $ref .Values.image.digest }}
{{- end }}
{{- $ref }}
{{- end }}

{{/*
The enabled steps, as the comma-separated list the cleanup script reads.
*/}}
{{- define "harddisk-hoover.steps" -}}
{{- $names := dict "logs" "logs" "archivedLogs" "archived-logs" "podLogs" "pod-logs" "coreDumps" "core-dumps" "journal" "journal" "packageCache" "package-cache" "exitedContainers" "exited-containers" "images" "images" }}
{{- $on := list }}
{{- range $key := list "logs" "archivedLogs" "podLogs" "coreDumps" "journal" "packageCache" "exitedContainers" "images" }}
{{- if index $.Values.steps $key }}
{{- $on = append $on (index $names $key) }}
{{- end }}
{{- end }}
{{- join "," $on }}
{{- end }}

{{/*
The per-node cleanup pod. The controller substitutes __NODE_NAME__ and __RUN_ID__ and
creates one of these per node, so everything about the pod is decided here, in values.
*/}}
{{- define "harddisk-hoover.cleanupPod" -}}
apiVersion: v1
kind: Pod
metadata:
  generateName: {{ include "harddisk-hoover.fullname" . | trunc 50 | trimSuffix "-" }}-
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "harddisk-hoover.labels" . | nindent 4 }}
    app.kubernetes.io/component: cleanup
    harddisk-hoover/node: "__NODE_NAME__"
    harddisk-hoover/run: "__RUN_ID__"
    {{- with .Values.cleanup.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with .Values.cleanup.podAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  nodeName: "__NODE_NAME__"
  restartPolicy: Never
  hostPID: true
  {{- /* No API credentials: the account itself turns token mounting off (serviceaccount.yaml). */}}
  serviceAccountName: {{ include "harddisk-hoover.cleanupServiceAccount" . }}
  enableServiceLinks: false
  {{- with .Values.cleanup.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  terminationGracePeriodSeconds: 30
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.cleanup.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: hoover
      image: {{ include "harddisk-hoover.image" . }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      command: ["/usr/local/bin/hoover"]
      env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: HOOVER_RUN_ID
          value: "__RUN_ID__"
        - name: HOOVER_HOST_ROOT
          value: /host
        - name: HOOVER_DRY_RUN
          value: {{ .Values.dryRun | quote }}
        - name: HOOVER_THRESHOLD_PERCENT
          value: {{ int .Values.threshold.percent | quote }}
        - name: HOOVER_THRESHOLD_PATH
          value: {{ .Values.threshold.path | quote }}
        - name: HOOVER_STEPS
          value: {{ include "harddisk-hoover.steps" . | quote }}
        - name: HOOVER_LOG_DIRS
          value: {{ join "," .Values.limits.logDirs | quote }}
        - name: HOOVER_LOG_MAX_SIZE
          value: {{ .Values.limits.logMaxSize | quote }}
        - name: HOOVER_POD_LOG_MAX_AGE_DAYS
          value: {{ int .Values.limits.podLogMaxAgeDays | quote }}
        - name: HOOVER_CORE_DUMP_MIN_SIZE
          value: {{ .Values.limits.coreDumpMinSize | quote }}
        - name: HOOVER_JOURNAL_MAX_SIZE
          value: {{ .Values.limits.journalMaxSize | quote }}
        - name: HOOVER_EXITED_CONTAINER_MIN_AGE_HOURS
          value: {{ int .Values.limits.exitedContainerMinAgeHours | quote }}
        - name: HOOVER_IMAGES_TARGET_PERCENT
          value: {{ int .Values.limits.imagesTargetPercent | quote }}
        - name: HOOVER_CRI_SOCKET
          value: {{ .Values.criSocket | quote }}
      securityContext:
        privileged: true
        runAsUser: 0
        runAsGroup: 0
        readOnlyRootFilesystem: true
      {{- with .Values.cleanup.resources }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        {{- /* HostToContainer: a volume the node unmounts while the cleanup runs (a CSI
        or Longhorn unstage) is unmounted here too, so this pod never keeps its block
        device busy. Needs / to be a shared mount on the node, the systemd default. */}}
        - name: host
          mountPath: /host
          mountPropagation: HostToContainer
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: host
      hostPath:
        path: /
        type: Directory
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
{{- end }}
