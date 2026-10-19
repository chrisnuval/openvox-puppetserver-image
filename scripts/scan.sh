#!/bin/bash
# Vulnerability scan + lint + Kubernetes policy check. Needs only podman (or docker):
# tools that aren't installed locally run as pinned containers.
#
#   scripts/scan.sh [image]                  default image: openvox-server-ubi:8.17.0
#   ENGINE=docker scripts/scan.sh ...
#   OFFLINE=1 scripts/scan.sh ...            no tool containers; policy check uses the image's own Ruby
#
# Reports go to scans/. Exit code: 0 if no FIXABLE vulnerabilities, no lint errors and no policy
# failures other than CKV_K8S_43 (image digest; only fixable once the image is pushed).
set -uo pipefail
cd "$(dirname "$0")/.."
image=${1:-openvox-server-ubi:8.17.0}
engine=${ENGINE:-podman}
z=$([ "$engine" = podman ] && echo ",Z")   # SELinux relabel for podman bind mounts
TRIVY_IMAGE=docker.io/aquasec/trivy:0.76.0
CHECKOV_IMAGE=docker.io/bridgecrew/checkov:3.3.20
HADOLINT_IMAGE=docker.io/hadolint/hadolint:v2.15.1
mkdir -p scans
status=0
report="scans/$(echo "$image" | tr '/:' '__')"

echo "== Trivy: $image"
if [ -z "${OFFLINE:-}" ] || command -v trivy >/dev/null; then
  if command -v trivy >/dev/null; then
    trivy image --quiet --scanners vuln --format json -o "$report.json" "$image"
  else
    # Scan a saved tarball: no podman socket needed
    $engine save -o scans/image.tar "$image" >/dev/null
    $engine run --rm -v "$PWD/scans:/scans:rw$z" -v trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" \
      image --quiet --scanners vuln --format json -o "/scans/$(basename "$report").json" --input /scans/image.tar
    rm -f scans/image.tar
  fi
  if command -v python3 >/dev/null; then
    python3 scripts/cve-summary.py "$image" "$report.json"
  fi
  fixable=$(grep -o '"FixedVersion": *"[^"]' "$report.json" | wc -l | tr -d ' ')
  echo "  fixable vulnerabilities: $fixable"
  [ "$fixable" -eq 0 ] || status=1
else
  echo "  skipped (OFFLINE and no local trivy); rely on your Aqua scan"
fi

for cf in Containerfile openvoxdb/Containerfile; do
  echo; echo "== Hadolint: $cf"
  if command -v hadolint >/dev/null; then
    hadolint "$cf" && echo "  clean" || status=1
  elif [ -z "${OFFLINE:-}" ]; then
    $engine run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro$z" "$HADOLINT_IMAGE" hadolint - < "$cf" \
      && echo "  clean" || status=1
  else
    echo "  skipped (OFFLINE)"
  fi
done

echo; echo "== Kubernetes policy: k8s/"
policy_out=scans/policy.txt
if command -v checkov >/dev/null; then
  checkov -d k8s --skip-path migration --framework kubernetes --compact --quiet > "$policy_out" 2>&1
elif [ -z "${OFFLINE:-}" ]; then
  $engine run --rm -v "$PWD/k8s:/k8s:ro$z" "$CHECKOV_IMAGE" -d /k8s --skip-path migration --framework kubernetes --compact --quiet > "$policy_out" 2>&1
else
  # Same check IDs as Checkov, using a local Ruby or the Ruby inside the server image
  # (POLICY_IMAGE; defaults to the image under test, set it to the server image when scanning OpenVoxDB)
  manifests=$(cd k8s && ls ./*.yaml | sed 's#^\./##')
  if command -v ruby >/dev/null; then
    # shellcheck disable=SC2086
    (cd k8s && ruby ../scripts/k8s-policy-check.rb $manifests) > "$policy_out" 2>&1
  else
    # shellcheck disable=SC2046
    $engine run --rm -v "$PWD/k8s:/k8s:ro$z" -v "$PWD/scripts:/scripts:ro$z" --entrypoint ruby "${POLICY_IMAGE:-$image}" \
      /scripts/k8s-policy-check.rb $(printf '/k8s/%s ' $manifests) > "$policy_out" 2>&1
    if ! grep -q 'Passed checks' "$policy_out"; then
      echo "  policy check could not run: no Ruby in ${POLICY_IMAGE:-$image}." \
           "Set POLICY_IMAGE to the server image (it has Ruby), e.g. POLICY_IMAGE=openvox-server-ubi:8.17.0" >&2
    fi
  fi
fi
grep -E "Passed checks|FAIL|Check: CKV" "$policy_out" | sed 's/^/  /'
# Failed check IDs: Ruby checker prints "FAIL  <id>", Checkov prints the id on the line before "FAILED"
failed_ids=$( { grep -E '^FAIL ' "$policy_out" | awk '{print $2}'
                grep -B1 'FAILED for' "$policy_out" | grep -oE 'CKV2?_K8S_[0-9]+'; } | sort -u)
if [ -z "$(grep -E 'Passed checks' "$policy_out")" ] || echo "$failed_ids" | grep -qvE '^(CKV_K8S_43)?$'; then
  status=1
fi

echo
[ "$status" -eq 0 ] && echo "SCAN OK" || echo "SCAN FOUND PROBLEMS"
exit "$status"
