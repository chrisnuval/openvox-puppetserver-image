#!/bin/bash
# Rehearse the Helm migration in a THROWAWAY namespace: install the chart the old way, upgrade to
# the hardened setup (image + values-hardened.yaml + post-renderer), verify, then roll back.
#
#   NS=openvox-rehearsal CHART=<chart dir or repo/chart> \
#   OLD_ARGS="-f my-values.yaml --set puppetserver.image=ghcr.io/openvoxproject/openvoxserver --set puppetserver.tag=8.8.1-v1.0.0" \
#   NEW_ARGS="-f my-values.yaml -f helm/values-hardened.yaml --set puppetserver.image=<registry>/openvox-server-ubi --set puppetserver.tag=8.17.0" \
#   scripts/helm-migration-test.sh
#
# Needs helm (3 or 4) and kubectl pointed at a NON-production cluster/namespace. The namespace is
# created and, with CLEANUP=1, deleted afterwards (including its PVCs).
set -uo pipefail
cd "$(dirname "$0")/.."
: "${NS:?set NS to a throwaway namespace}" "${CHART:?set CHART}" "${OLD_ARGS:?}" "${NEW_ARGS:?}"
release=${RELEASE:-ovx}
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }

case "$NS" in *prod*) echo "Refusing: namespace name contains 'prod'"; exit 2;; esac

if helm version --short | grep -q '^v3'; then
  post=(--post-renderer ./helm/post-render/post-render.sh)
else
  helm plugin list | grep -q '^openvox-hardening' || helm plugin install ./helm/post-render >/dev/null
  post=(--post-renderer openvox-hardening)
fi

server_pod() { kubectl get pods -n "$NS" -l app.kubernetes.io/component=puppetserver \
  --field-selector=status.phase=Running -o name | tail -1; }
# the server container: not necessarily the first one (kustomize may put r10k sidecars first)
server_container() { kubectl get -n "$NS" "$(server_pod)" -o jsonpath='{.spec.containers[*].name}' \
  | tr ' ' '\n' | grep -v '^r10k-' | head -1; }
in_server() { kubectl exec -n "$NS" "$(server_pod)" -c "$(server_container)" -- "$@"; }
ca_fp() { in_server openssl x509 -noout -fingerprint -sha256 -in /etc/puppetlabs/puppetserver/ca/ca_crt.pem; }
wait_ready() {
  kubectl rollout status deployment -n "$NS" -l app.kubernetes.io/component=puppetserver --timeout=10m >/dev/null 2>&1 \
    || kubectl wait --for=condition=Ready pod -n "$NS" -l app.kubernetes.io/component=puppetserver --timeout=10m >/dev/null
  # the old pod may still be terminating; wait until only one server pod is left
  for _ in $(seq 1 60); do
    [ "$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=puppetserver -o name | wc -l)" -eq 1 ] && return 0
    sleep 5
  done
}
sign() {
  local name=$1 label=$2
  if in_server puppetserver ca generate --certname "$name" >/dev/null 2>&1 \
     && in_server test -f "/etc/puppetlabs/puppetserver/ca/signed/$name.pem"; then
    pass "$label"; in_server puppetserver ca clean --certname "$name" >/dev/null 2>&1
  else
    fail "$label"
  fi
}

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "== 1. old setup"
# shellcheck disable=SC2086
helm upgrade --install "$release" "$CHART" -n "$NS" $OLD_ARGS --wait --timeout 10m >/dev/null \
  && pass "old chart setup installed" || fail "old chart setup install"
wait_ready
fp_old=$(ca_fp); echo "      CA $fp_old"
owners=$(in_server sh -c 'stat -c "%u:%g" /etc/puppetlabs/puppetserver/ca/ca_key.pem /etc/puppetlabs/puppet/ssl/certs/ca.pem' | sort -u | tr '\n' ' ')
echo "      CA/ssl file owners in the old setup: $owners"

echo "== 2. protect PVCs, hand the volumes over to UID 64604 (old image as root), then upgrade"
pvc_uids() { kubectl get pvc -n "$NS" -l "app.kubernetes.io/instance=$release" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{"\n"}{end}' | sort; }
uids_before=$(pvc_uids); echo "      PVCs: $(echo "$uids_before" | cut -d= -f1 | tr '\n' ' ')"
# Safety net: Helm never deletes a live object annotated keep (protects the CA volume)
if [ "${SKIP_KEEP_ANNOTATION:-0}" = 1 ]; then
  echo "      (SKIP_KEEP_ANNOTATION=1: relying on the post-renderer alone to keep the PVCs)"
else
  kubectl annotate pvc -n "$NS" -l "app.kubernetes.io/instance=$release" helm.sh/resource-policy=keep --overwrite >/dev/null \
    && pass "PVCs annotated helm.sh/resource-policy=keep" || fail "annotate PVCs"
fi
deploy=$(kubectl get deploy -n "$NS" -l app.kubernetes.io/component=puppetserver -o name | head -1 | cut -d/ -f2)
old_image=$(kubectl get deploy "$deploy" -n "$NS" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$(server_container)\")].image}")
scripts/k8s-handover-volumes.sh "$NS" "$deploy" "$old_image" 64604:64604 >/dev/null \
  && pass "volumes handed over to 64604:64604" || fail "volume handover"

# shellcheck disable=SC2086
helm upgrade "$release" "$CHART" -n "$NS" $NEW_ARGS "${post[@]}" --wait --timeout 10m >/dev/null \
  && pass "helm upgrade to hardened setup" || fail "helm upgrade"
wait_ready
[ "$(pvc_uids)" = "$uids_before" ] && pass "PVCs kept (same UIDs, not recreated)" || fail "PVCs changed: $(pvc_uids | tr '\n' ' ')"
[ "$(in_server id -u)" = 64604 ] && pass "server runs as UID 64604" || fail "server UID: $(in_server id -u)"
in_server touch /usr/ro-test 2>/dev/null && fail "root filesystem is writable" || pass "root filesystem is read-only"
[ "$(ca_fp)" = "$fp_old" ] && pass "CA unchanged after upgrade" || fail "CA changed after upgrade"
sign upgrade-signing-test.invalid "CA can sign after upgrade"
rev_new=$(helm history "$release" -n "$NS" -o json | grep -o '"revision":[0-9]*' | tail -1 | cut -d: -f2)

owners_new=$(in_server sh -c 'stat -c "%u:%g" /etc/puppetlabs/puppetserver/ca/ca_key.pem' 2>/dev/null)
echo "      CA key owner after upgrade: $owners_new"
r10k=$(kubectl get -n "$NS" "$(server_pod)" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep '^r10k-code$' || true)
if [ -n "$r10k" ]; then
  kubectl exec -n "$NS" "$(server_pod)" -c r10k-code -- /etc/puppetlabs/puppet/r10k_code_cronjob.sh >/dev/null 2>&1 \
    && pass "r10k deploy works (read-only root)" || fail "r10k deploy"
fi

echo "== 3. helm rollback to the old setup"
helm rollback "$release" $((rev_new - 1)) -n "$NS" --wait --timeout 10m >/dev/null \
  && pass "helm rollback" || fail "helm rollback"
wait_ready
[ "$(ca_fp)" = "$fp_old" ] && pass "CA unchanged after rollback" || fail "CA changed after rollback"
sign rollback-signing-test.invalid "CA can sign after rollback"

if [ "${CLEANUP:-0}" = 1 ]; then
  helm uninstall "$release" -n "$NS" --wait >/dev/null; kubectl delete namespace "$NS" --wait=true >/dev/null
fi
echo
if [ "$failures" -eq 0 ]; then echo "ALL HELM MIGRATION TESTS PASSED"; else echo "$failures TEST(S) FAILED"; fi
exit "$failures"
