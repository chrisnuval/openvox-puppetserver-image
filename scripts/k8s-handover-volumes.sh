#!/bin/bash
# One-time ownership handover of a server's persistent volumes to the new runtime user.
#
#   scripts/k8s-handover-volumes.sh <namespace> <deployment> <old-image> [uid:gid]
#
# 1. scales the Deployment to 0 (ReadWriteOnce volumes must be free),
# 2. starts a maintenance pod from <old-image> as root with the Deployment's PVCs mounted at the
#    same paths as in the server container,
# 3. runs chown -R <uid:gid> (default 64604:64604) on every mounted PVC,
# 4. deletes the pod. The Deployment stays at 0 replicas: the following `helm upgrade` (or
#    kubectl apply) starts the new server.
#
# Why: the CA rewrites files keeping their owner; a non-root process can't keep an owner that
# isn't itself, so signing fails ("Operation not permitted") on volumes owned by another UID.
# Kubernetes fsGroup only changes the group and doesn't help.
#
# Use the OLD image: it is already approved in the cluster, runs as root and has chown/tar.
# Rollback direction: pass the old owner, e.g. 999:999 (the chart's root mode fixes it by itself).
set -euo pipefail
ns=${1:?namespace} deploy=${2:?deployment} image=${3:?old image} owner=${4:-64604:64604}
pod=openvox-maint

# The server container (r10k sidecars may come first after kustomize), its PVC volumes and mounts
server=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{.spec.template.spec.containers[*].name}' \
  | tr ' ' '\n' | grep -v '^r10k-' | head -1)
claims=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath='{range .spec.template.spec.volumes[?(@.persistentVolumeClaim)]}{.name}={.persistentVolumeClaim.claimName}{"\n"}{end}')
mounts=$(kubectl get deploy "$deploy" -n "$ns" -o jsonpath="{range .spec.template.spec.containers[?(@.name==\"$server\")].volumeMounts[*]}{.name}={.mountPath}{\"\\n\"}{end}")
[ -n "$claims" ] || { echo "No PVC volumes on deployment/$deploy" >&2; exit 1; }

volumes="" volume_mounts="" paths=""
while IFS='=' read -r vname claim; do
  path=$(echo "$mounts" | awk -F= -v n="$vname" '$1 == n {print $2; exit}')
  [ -n "$path" ] || { echo "skip $vname ($claim): not mounted in the server container"; continue; }
  volumes+="    - {name: $vname, persistentVolumeClaim: {claimName: $claim}}"$'\n'
  volume_mounts+="        - {name: $vname, mountPath: $path}"$'\n'
  paths+=" $path"
  echo "volume $claim -> $path"
done <<< "$claims"

echo "scaling deployment/$deploy to 0"
kubectl scale deploy "$deploy" -n "$ns" --replicas=0
selector=$(kubectl get deploy "$deploy" -n "$ns" \
  -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
kubectl wait --for=delete pod -n "$ns" -l "$selector" --timeout=5m 2>/dev/null || true

kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $ns
  labels: {app.kubernetes.io/name: openvox-maint}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: maint
      image: $image
      command: ["sleep", "infinity"]
      securityContext: {runAsUser: 0}
      volumeMounts:
$volume_mounts  volumes:
$volumes
YAML
kubectl wait --for=condition=Ready "pod/$pod" -n "$ns" --timeout=5m
# shellcheck disable=SC2086
kubectl exec -n "$ns" "$pod" -- chown -R "$owner" $paths
kubectl exec -n "$ns" "$pod" -- sh -c "stat -c '%u:%g %n' $paths"
kubectl delete pod "$pod" -n "$ns" --wait=true
echo "done: volumes owned by $owner; deployment/$deploy is at 0 replicas"
