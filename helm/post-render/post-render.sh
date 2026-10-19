#!/bin/bash
# Helm post-renderer: reads the rendered chart on stdin, writes the hardened manifests to stdout.
#   Helm 3:  helm upgrade --install ... --post-renderer ./helm/post-render/post-render.sh
#   Helm 4:  helm plugin install ./helm/post-render   (once), then --post-renderer openvox-hardening
#   Any:     helm template ... | ./helm/post-render/post-render.sh > manifests.yaml
# Needs kubectl (built-in kustomize) or a standalone kustomize binary.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cp -R "$here/kustomization.yaml" "$here/patches" "$work/"
# PVCs must stay normal release resources (see kustomization.yaml): drop their helm.sh/hook
# annotation. Works per YAML document; other kinds (real hooks) are left untouched.
awk '
  function flush() { if (doc != "") { if (doc ~ /\nkind: PersistentVolumeClaim\n/) gsub(/\n[ \t]+"?helm\.sh\/hook"?:[^\n]*/, "", doc); printf "%s", doc }; doc = "" }
  /^---/ { flush(); print; next }
  { doc = doc $0 "\n" }
  END { flush() }' > "$work/rendered.yaml"

# Data dir: chart mounts a PVC there only if puppetserver.persistence.data.enabled; otherwise add an emptyDir
if ! grep -qE '^\s+mountPath: "?/opt/puppetlabs/server/data/puppetserver/?"?\s*$' "$work/rendered.yaml"; then
  cat >> "$work/kustomization.yaml" <<'YAML'
  - path: patches/puppetserver-data.yaml
    target:
      kind: Deployment
      labelSelector: app.kubernetes.io/component=puppetserver
YAML
fi
# r10k sidecars (code/hiera, present only when configured). Their root filesystem is made
# read-only through values (r10k.containerSecurityContext); here they get:
#  - a writable /tmp and home (the entrypoint writes ~/.r10k_*_crontab), and /etc/puppetlabs/r10k
#    (10-create_r10k_config.sh writes a default r10k.yaml there; the chart uses its own --config)
#  - an /etc/passwd with an entry for UID 64604: the r10k image's 05-add_passwd_entry.sh
#    otherwise tries to append one, which fails on a read-only root and aborts every deploy.
#    A non-root init container (same image) writes image passwd + entry into an emptyDir.
sidecars=$(grep -oE '^\s+- name: r10k-(code|hiera)\s*$' "$work/rendered.yaml" | awk '{print $3}' | sort -u || true)
if [ -n "$sidecars" ]; then
  first=$(echo "$sidecars" | head -1)
  # image and pull policy of the first r10k sidecar, so the init container follows your values
  read -r r10k_image r10k_pull < <(awk -v n="$first" '
    $0 ~ "^[[:space:]]+- name: "n"[[:space:]]*$" {f=1; next}
    f && /^[[:space:]]+image:/ {gsub(/"/,""); img=$2}
    f && /^[[:space:]]+imagePullPolicy:/ {gsub(/"/,""); pol=$2}
    f && img && pol {print img, pol; exit}' "$work/rendered.yaml")
  {
    echo "apiVersion: apps/v1"
    echo "kind: Deployment"
    echo "metadata: {name: ignored}"
    echo "spec:"
    echo "  template:"
    echo "    spec:"
    echo "      volumes:"
    echo "        - {name: ovx-r10k-tmp, emptyDir: {}}"
    echo "        - {name: ovx-r10k-home, emptyDir: {}}"
    echo "        - {name: ovx-r10k-etc, emptyDir: {sizeLimit: 1Mi}}"
    echo "        - {name: ovx-r10k-passwd, emptyDir: {sizeLimit: 1Mi}}"
    echo "      initContainers:"
    echo "        - name: r10k-passwd"
    echo "          image: ${r10k_image}"
    echo "          imagePullPolicy: ${r10k_pull:-Always}"
    echo "          command: [\"/bin/sh\", \"-c\"]"
    echo "          args: ['cat /etc/passwd > /out/passwd && echo \"puppet:x:64604:0:r10k:/home/puppet:/bin/sh\" >> /out/passwd']"
    echo "          securityContext:"
    echo "            runAsUser: 64604"
    echo "            runAsNonRoot: true"
    echo "            readOnlyRootFilesystem: true"
    echo "            allowPrivilegeEscalation: false"
    echo "            capabilities: {drop: [ALL]}"
    echo "          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 32Mi}}"
    echo "          volumeMounts: [{name: ovx-r10k-passwd, mountPath: /out}]"
    echo "      containers:"
    for c in $sidecars; do
      echo "        - name: $c"
      echo "          volumeMounts:"
      echo "            - {name: ovx-r10k-tmp, mountPath: /tmp}"
      echo "            - {name: ovx-r10k-home, mountPath: /home/puppet}"
      echo "            - {name: ovx-r10k-etc, mountPath: /etc/puppetlabs/r10k}"
      echo "            - {name: ovx-r10k-passwd, mountPath: /etc/passwd, subPath: passwd, readOnly: true}"
    done
  } > "$work/patches/r10k.yaml"
  cat >> "$work/kustomization.yaml" <<'YAML'
  - path: patches/r10k.yaml
    target:
      kind: Deployment
      labelSelector: app.kubernetes.io/component=puppetserver
YAML
fi

if command -v kustomize >/dev/null; then kustomize build "$work"; else kubectl kustomize "$work"; fi
