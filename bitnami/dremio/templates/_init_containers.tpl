
{{/*
Init container definition for generating the configuration
*/}}
{{- define "dremio.init-containers.generate-conf" -}}
# This init container renders and merges the Dremio configuration files.
# We need to use a volume because we're working with ReadOnlyRootFilesystem
- name: generate-conf
  image: {{ include "dremio.init-containers.default-image" .context }}
  imagePullPolicy: {{ .context.Values.defaultInitContainers.defaultImage.pullPolicy }}
  {{- if .context.Values.defaultInitContainers.generateConf.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" .context.Values.defaultInitContainers.generateConf.containerSecurityContext "context" .context) | nindent 4 }}
  {{- end }}
  {{- if .context.Values.defaultInitContainers.generateConf.resources }}
  resources: {{- toYaml .context.Values.defaultInitContainers.generateConf.resources | nindent 4 }}
  {{- else if ne .context.Values.defaultInitContainers.generateConf.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" .context.Values.defaultInitContainers.generateConf.resourcesPreset) | nindent 4 }}
  {{- end }}
  command:
    - bash
  args:
    - -ec
    - |
      set -e
      {{- if .context.Values.usePasswordFile }}
      # We need to load all the secret env vars to the system
      for file in $(find /bitnami/dremio/secrets -type f); do
          env_var_name="$(basename $file)"
          echo "Exporting $env_var_name"
          export $env_var_name="$(< $file)"
      done
      {{- end }}

      # dremio.conf -> We concatenate the configuration from configmap + secret and then
      # perform render-template to substitute all the environment variable references

      echo "Expanding env vars from dremio.conf"
      find /bitnami/dremio/input-dremio -type f -name dremio.conf -print0 | sort -z | xargs -0 cat > /bitnami/dremio/rendered-conf/pre-render-dremio.conf
      render-template /bitnami/dremio/rendered-conf/pre-render-dremio.conf > /bitnami/dremio/rendered-conf/dremio.conf
      rm /bitnami/dremio/rendered-conf/pre-render-dremio.conf

      # Files different from dremio.conf -> Here we only apply render-template to expand the env vars
      for file in $(find /bitnami/dremio/input-dremio -type f -not -name dremio.conf); do
          filename="$(basename $file)"
          echo "Expanding env vars from $filename"
          render-template "$file" > /bitnami/dremio/rendered-conf/$filename
      done
      echo "Configuration generated"
  env:
    - name: BITNAMI_DEBUG
      value: {{ ternary "true" "false" (or .context.Values.dremio.image.debug .context.Values.diagnosticMode.enabled) | quote }}
    {{- if not .context.Values.usePasswordFile }}
    {{- if or .context.Values.dremio.tls.passwordSecret .context.Values.dremio.tls.password .context.Values.dremio.tls.autoGenerated.enabled .context.Values.dremio.tls.usePemCerts }}
    - name: DREMIO_KEYSTORE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "dremio.tls.passwordSecretName" .context }}
          key: keystore-password
    {{- end }}
    {{- if or (eq .context.Values.dremio.distStorageType "minio") (eq .context.Values.dremio.distStorageType "aws") }}
    - name: DREMIO_AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: {{ include "dremio.s3.secretName" .context }}
          key: {{ include "dremio.s3.accessKeyIDKey" .context | quote }}
    - name: DREMIO_AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: {{ include "dremio.s3.secretName" .context }}
          key: {{ include "dremio.s3.secretAccessKeyKey" .context | quote }}
    {{- end }}
    {{- end }}
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    {{- if .context.Values.defaultInitContainers.generateConf.extraEnvVars }}
    {{- include "common.tplvalues.render" (dict "value" .context.Values.defaultInitContainers.generateConf.extraEnvVars "context" $) | nindent 4 }}
    {{- end }}
  envFrom:
    {{- if .context.Values.defaultInitContainers.generateConf.extraEnvVarsCM }}
    - configMapRef:
        name: {{ include "common.tplvalues.render" (dict "value" .context.Values.defaultInitContainers.generateConf.extraEnvVarsCM "context" .context) }}
    {{- end }}
    {{- if .context.Values.defaultInitContainers.generateConf.extraEnvVarsSecret }}
    - secretRef:
        name: {{ include "common.tplvalues.render" (dict "value" .context.Values.defaultInitContainers.generateConf.extraEnvVarsSecret "context" .context) }}
    {{- end }}
  volumeMounts:
    - name: input-dremio-conf-cm
      mountPath: /bitnami/dremio/input-dremio/dremio-conf/configmap
    {{- if .mountDremioConfSecret }}
    - name: input-dremio-conf-secret
      mountPath: /bitnami/dremio/input-dremio/dremio-conf/secret
    {{- end }}
    - name: input-core-site
      mountPath: /bitnami/dremio/input-dremio/core-site
    - name: empty-dir
      mountPath: /tmp
      subPath: tmp-dir
    - name: empty-dir
      mountPath: /bitnami/dremio/rendered-conf
      subPath: app-conf-dir
    {{- if .context.Values.usePasswordFile }}
    {{- if or .context.Values.dremio.tls.passwordSecret .context.Values.dremio.tls.password .context.Values.dremio.tls.autoGenerated.enabled .context.Values.dremio.tls.usePemCerts }}
    - name: keystore-password
      mountPath: /bitnami/dremio/secrets/keystore-password
    {{- end }}
    {{- if or (eq .context.Values.dremio.distStorageType "minio") (eq .context.Values.dremio.distStorageType "aws") }}
    - name: s3-credentials
      mountPath: /bitnami/dremio/secrets/s3-credentials
    {{- end }}
    {{- end }}
    {{- if .context.Values.defaultInitContainers.generateConf.extraVolumeMounts }}
    {{- include "common.tplvalues.render" (dict "value" .context.Values.defaultInitContainers.generateConf.extraVolumeMounts "context" .context) | nindent 4 }}
    {{- end }}
{{- end -}}

{{- define "dremio.init-containers.volume-permissions" -}}
{{- /* As most Bitnami charts have volumePermissions in the root, we add this overwrite to maintain a similar UX */}}
{{- $volumePermissionsValues := mustMergeOverwrite .context.Values.defaultInitContainers.volumePermissions .context.Values.volumePermissions }}
- name: volume-permissions
  image: {{ include "dremio.init-containers.default-image" . }}
  imagePullPolicy: {{ .context.Values.defaultInitContainers.defaultImage.pullPolicy | quote }}
  command:
    - /bin/bash
    - -ec
    - |
      {{- if eq ( toString ( $volumePermissionsValues.containerSecurityContext.runAsUser )) "auto" }}
      chown -R `id -u`:`id -G | cut -d " " -f2` {{ .componentValues.persistence.mountPath }}
      {{- else }}
      chown -R {{ .componentValues.containerSecurityContext.runAsUser }}:{{ .componentValues.podSecurityContext.fsGroup }} {{ .componentValues.persistence.mountPath }}
      {{- end }}
  {{- if $volumePermissionsValues.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" $volumePermissionsValues.containerSecurityContext "context" $) | nindent 4 }}
  {{- end }}
  {{- if $volumePermissionsValues.resources }}
  resources: {{- toYaml $volumePermissionsValues.resources | nindent 4 }}
  {{- else if ne $volumePermissionsValues.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" $volumePermissionsValues.resourcesPreset) | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: data
      mountPath: {{ .componentValues.persistence.mountPath }}
      {{- if .componentValues.persistence.subPath }}
      subPath: {{ .componentValues.persistence.subPath }}
      {{- end }}
{{- end -}}

{{/*
Init container definition for waiting for the database to be ready
*/}}
{{- define "dremio.init-containers.wait-for-zookeeper" -}}
- name: wait-for-zookeeper
  image: {{ include "dremio.init-containers.default-image" . }}
  imagePullPolicy: {{ .Values.defaultInitContainers.defaultImage.pullPolicy }}
  {{- if .Values.defaultInitContainers.wait.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" .Values.defaultInitContainers.wait.containerSecurityContext "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.defaultInitContainers.wait.resources }}
  resources: {{- toYaml .Values.defaultInitContainers.wait.resources | nindent 4 }}
  {{- else if ne .Values.defaultInitContainers.wait.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" .Values.defaultInitContainers.wait.resourcesPreset) | nindent 4 }}
  {{- end }}
  command:
    - bash
  args:
    - -ec
    - |
      retry_while() {
          local -r cmd="${1:?cmd is missing}"
          local -r retries="${2:-12}"
          local -r sleep_time="${3:-5}"
          local return_value=1

          read -r -a command <<< "$cmd"
          for ((i = 1 ; i <= retries ; i+=1 )); do
              "${command[@]}" && return_value=0 && break
              sleep "$sleep_time"
          done
          return $return_value
      }

      zookeeper_hosts=(
      {{- if .Values.zookeeper.enabled  }}
          {{ include "dremio.zookeeper.fullname" . | quote }}
      {{- else }}
      {{- range $node :=.Values.externalZookeeper.servers }}
          {{ print $node | quote }}
      {{- end }}
      {{- end }}
      )

      check_zookeeper() {
          local -r zookeeper_host="${1:-?missing zookeeper}"
          if wait-for-port --timeout=5 --host=${zookeeper_host} --state=inuse {{ include "dremio.zookeeper.port" . }}; then
              return 0
          else
              return 1
          fi
      }

      for host in "${zookeeper_hosts[@]}"; do
          echo "Checking connection to $host"
          if retry_while "check_zookeeper $host"; then
              echo "Connected to $host"
          else
              echo "Error connecting to $host"
              exit 1
          fi
      done

      echo "Connection success"
      exit 0
{{- end -}}

{{/*
Init container definition for waiting for the database to be ready
*/}}
{{- define "dremio.init-containers.init-certs" -}}
- name: init-certs
  image: {{ include "dremio.image" . }}
  imagePullPolicy: {{ .Values.dremio.image.pullPolicy }}
  {{- if .Values.defaultInitContainers.initCerts.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" .Values.defaultInitContainers.initCerts.containerSecurityContext "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.defaultInitContainers.initCerts.resources }}
  resources: {{- toYaml .Values.defaultInitContainers.initCerts.resources | nindent 4 }}
  {{- else if ne .Values.defaultInitContainers.initCerts.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" .Values.defaultInitContainers.initCerts.resourcesPreset) | nindent 4 }}
  {{- end }}
  command:
    - bash
  args:
    - -ec
    - |
      set -e
      {{- if .context.Values.usePasswordFile }}
      # We need to load all the secret env vars to the system
      for file in $(find /bitnami/dremio/secrets -type f); do
          env_var_name="$(basename $file)"
          echo "Exporting $env_var_name"
          export $env_var_name="$(< $file)"
      done
      {{- end }}
      {{- if .Values.dremio.tls.usePemCerts }}
      if [[ -f "/certs/tls.key" ]] && [[ -f "/certs/tls.crt" ]]; then
          openssl pkcs12 -export -in "/certs/tls.crt" \
              -passout pass:"${DREMIO_KEYSTORE_PASSWORD}" \
              -inkey "/certs/tls.key" \
              -out "/tmp/keystore.p12"
          keytool -importkeystore -srckeystore "/tmp/keystore.p12" \
              -srcstoretype PKCS12 \
              -srcstorepass "${DREMIO_KEYSTORE_PASSWORD}" \
              -deststorepass "${DREMIO_KEYSTORE_PASSWORD}" \
              -destkeystore "/opt/bitnami/dremio/certs/dremio.jks"
          rm "/tmp/keystore.p12"
      else
          echo "Couldn't find the expected PEM certificates! They are mandatory when encryption via TLS is enabled."
          exit 1
      fi
      {{- else }}
      if [[ -f "/certs/dremio.jks" ]]; then
          cp "/certs/dremio.jks" "/opt/bitnami/dremio/certs/dremio.jks"
      else
          echo "Couldn't find the expected Java Key Stores (JKS) files! They are mandatory when encryption via TLS is enabled."
          exit 1
      fi
      {{- end }}
  env:
    {{- if not .Values.usePasswordFile }}
    {{- if or .Values.dremio.tls.passwordSecret .Values.dremio.tls.password .Values.dremio.tls.autoGenerated.enabled .Values.dremio.tls.usePemCerts }}
    - name: DREMIO_KEYSTORE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ include "dremio.tls.passwordSecretName" . }}
          key: keystore-password
    {{- end }}
    {{- end }}
  volumeMounts:
    - name: input-tls-certs
      mountPath: /certs
    - name: empty-dir
      mountPath: /opt/bitnami/dremio/certs
      subPath: app-processed-certs-dir
    - name: empty-dir
      mountPath: /tmp
      subPath: tmp-dir
    {{- if .Values.usePasswordFile }}
    {{- if or .Values.dremio.tls.passwordSecret .Values.dremio.tls.password .Values.dremio.tls.autoGenerated.enabled .Values.dremio.tls.usePemCerts }}
    - name: keystore-password
      mountPath: /bitnami/dremio/secrets/keystore-password
    {{- end }}
    {{- end }}
{{- end -}}

{{/*
Init container definition for waiting for the database to be ready
*/}}
{{- define "dremio.init-containers.copy-default-conf" -}}
- name: copy-default-conf
  image: {{ include "dremio.image" . }}
  imagePullPolicy: {{ .Values.dremio.image.pullPolicy }}
  {{- if .Values.defaultInitContainers.copyDefaultConf.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" .Values.defaultInitContainers.copyDefaultConf.containerSecurityContext "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.defaultInitContainers.copyDefaultConf.resources }}
  resources: {{- toYaml .Values.defaultInitContainers.copyDefaultConf.resources | nindent 4 }}
  {{- else if ne .Values.defaultInitContainers.copyDefaultConf.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" .Values.defaultInitContainers.copyDefaultConf.resourcesPreset) | nindent 4 }}
  {{- end }}
  command:
    - bash
  args:
    - -ec
    - |
      set -e
      echo "Copying configuration files from /opt/bitnami/dremio/conf to empty-dir volume"
      # First copy the default configuration files so we can fully replace the folder

      cp /opt/bitnami/dremio/conf/* /bitnami/dremio/conf/
  volumeMounts:
    - name: empty-dir
      mountPath: /bitnami/dremio/conf
      subPath: app-conf-dir
{{- end -}}

{{/*
Init container definition for waiting for the database to be ready
*/}}
{{- define "dremio.init-containers.upgrade-keystore" -}}
- name: upgrade-keystore
  image: {{ include "dremio.image" . }}
  imagePullPolicy: {{ .Values.dremio.image.pullPolicy }}
  {{- if .Values.defaultInitContainers.upgradeKeystore.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" .Values.defaultInitContainers.upgradeKeystore.containerSecurityContext "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.defaultInitContainers.upgradeKeystore.resources }}
  resources: {{- toYaml .Values.defaultInitContainers.upgradeKeystore.resources | nindent 4 }}
  {{- else if ne .Values.defaultInitContainers.upgradeKeystore.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" .Values.defaultInitContainers.upgradeKeystore.resourcesPreset) | nindent 4 }}
  {{- end }}
  command:
    - /opt/bitnami/scripts/dremio/entrypoint.sh
  args:
    - dremio-admin
    - upgrade
  env:
    - name: BITNAMI_DEBUG
      value: {{ ternary "true" "false" (or .Values.dremio.image.debug .Values.diagnosticMode.enabled) | quote }}
  volumeMounts:
    - name: empty-dir
      mountPath: /.dremio
      subPath: tmp-dir
    - name: data
      mountPath: {{ .Values.masterCoordinator.persistence.mountPath }}
      {{- if .Values.masterCoordinator.persistence.subPath }}
      subPath: {{ .Values.masterCoordinator.persistence.subPath }}
      {{- end }}
    - name: empty-dir
      mountPath: /tmp
      subPath: tmp-dir
    - name: empty-dir
      mountPath: /opt/bitnami/dremio/tmp
      subPath: app-tmp-dir
    - name: empty-dir
      mountPath: /opt/bitnami/dremio/run
      subPath: app-run-dir
    - name: empty-dir
      mountPath: /opt/bitnami/dremio/log
      subPath: app-log-dir
    - name: empty-dir
      mountPath: /opt/bitnami/dremio/conf
      subPath: app-conf-dir
    {{- if .Values.dremio.tls.enabled }}
    - name: empty-dir
      mountPath: /opt/bitnami/dremio/certs
      subPath: app-processed-certs-dir
    {{- end }}
{{- end -}}

{{/*
Init container definition for waiting for the database to be ready
*/}}
{{- define "dremio.init-containers.wait-for-s3" -}}
- name: wait-for-s3
  image: {{ include "dremio.init-containers.default-image" . }}
  imagePullPolicy: {{ .Values.defaultInitContainers.defaultImage.pullPolicy }}
  {{- if .Values.defaultInitContainers.wait.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" .Values.defaultInitContainers.wait.containerSecurityContext "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.defaultInitContainers.wait.resources }}
  resources: {{- toYaml .Values.defaultInitContainers.wait.resources | nindent 4 }}
  {{- else if ne .Values.defaultInitContainers.wait.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" .Values.defaultInitContainers.wait.resourcesPreset) | nindent 4 }}
  {{- end }}
  command:
    - bash
  args:
    - -ec
    - |
      retry_while() {
          local -r cmd="${1:?cmd is missing}"
          local -r retries="${2:-12}"
          local -r sleep_time="${3:-5}"
          local return_value=1

          read -r -a command <<< "$cmd"
          for ((i = 1 ; i <= retries ; i+=1 )); do
              "${command[@]}" && return_value=0 && break
              sleep "$sleep_time"
          done
          return $return_value
      }

      check_s3() {
          local -r s3_host="${1:-?missing s3}"
          if curl -k --max-time 5 "${s3_host}" | grep "RequestId"; then
              return 0
          else
              return 1
          fi
      }

      host={{ printf "%s://%v:%v" (include "dremio.s3.protocol" .) (include "dremio.s3.host" .) (include "dremio.s3.port" .) }}

      echo "Checking connection to $host"
      if retry_while "check_s3 $host"; then
          echo "Connected to $host"
      else
          echo "Error connecting to $host"
          exit 1
      fi

      echo "Connection success"
      exit 0
{{- end -}}

{{/*
Init container definition for waiting for the database to be ready
*/}}
{{- define "dremio.init-containers.wait-for-master-coordinator" -}}
- name: wait-for-master-coordinator
  image: {{ include "dremio.init-containers.default-image" . }}
  imagePullPolicy: {{ .Values.defaultInitContainers.defaultImage.pullPolicy }}
  {{- if .Values.defaultInitContainers.wait.containerSecurityContext.enabled }}
  securityContext: {{- include "common.compatibility.renderSecurityContext" (dict "secContext" .Values.defaultInitContainers.wait.containerSecurityContext "context" $) | nindent 4 }}
  {{- end }}
  {{- if .Values.defaultInitContainers.wait.resources }}
  resources: {{- toYaml .Values.defaultInitContainers.wait.resources | nindent 4 }}
  {{- else if ne .Values.defaultInitContainers.wait.resourcesPreset "none" }}
  resources: {{- include "common.resources.preset" (dict "type" .Values.defaultInitContainers.wait.resourcesPreset) | nindent 4 }}
  {{- end }}
  command:
    - bash
  args:
    - -ec
    - |
      retry_while() {
          local -r cmd="${1:?cmd is missing}"
          local -r retries="${2:-12}"
          local -r sleep_time="${3:-5}"
          local return_value=1

          read -r -a command <<< "$cmd"
          for ((i = 1 ; i <= retries ; i+=1 )); do
              "${command[@]}" && return_value=0 && break
              sleep "$sleep_time"
          done
          return $return_value
      }

      check_master_coordinator() {
          local -r master_coordinator_host="${1:-?missing master_coordinator}"
          if curl -k --max-time 5 "${master_coordinator_host}" | grep dremio; then
              return 0
          else
              return 1
          fi
      }

      host="{{ ternary "https" "http" .Values.dremio.tls.enabled }}://{{ include "dremio.master-coordinator.fullname" . }}-0.{{ printf "%s-headless" (include "common.names.fullname" .) | trunc 63 | trimSuffix "-" }}:{{ .Values.dremio.containerPorts.web }}"

      echo "Checking connection to $host"
      if retry_while "check_master_coordinator $host"; then
          echo "Connected to $host"
      else
          echo "Error connecting to $host"
          exit 1
      fi

      echo "Connection success"
      exit 0
{{- end -}}