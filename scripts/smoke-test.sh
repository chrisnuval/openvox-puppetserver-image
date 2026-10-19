#!/bin/bash
# Functional tests for the image. Works with podman (default) or docker.
#
#   scripts/smoke-test.sh <image> [old-image]
#     ENGINE=docker scripts/smoke-test.sh openvox-server-ubi:8.17.0
#
# With [old-image] (e.g. ghcr.io/openvoxproject/openvoxserver:8.8.1-v1.0.0) it also runs the
# migration test: the old image creates a CA on a volume, the new image must reuse it unchanged.
# Prints PASS/FAIL per test; exits non-zero if anything failed.

set -uo pipefail
image=${1:?usage: smoke-test.sh <image> [old-image]}
old_image=${2:-}
engine=${ENGINE:-podman}
prefix=ovx-smoke-$$
failures=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
cleanup() {
  $engine rm -f "$prefix-plain" "$prefix-ro" "$prefix-old" "$prefix-new" >/dev/null 2>&1
  $engine volume rm -f "$prefix-etc" >/dev/null 2>&1
}
trap cleanup EXIT

# Wait until /status/v1/simple says "running" (engine-independent; no HEALTHCHECK needed)
wait_running() {
  local name=$1 i
  for i in $(seq 1 60); do
    if [ "$($engine exec "$name" curl -sk "https://localhost:8140/status/v1/simple" 2>/dev/null)" = running ]; then
      return 0
    fi
    [ "$($engine inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] || break
    sleep 5
  done
  $engine logs "$name" 2>&1 | tail -30
  return 1
}

# Compile a catalog through the API using the server's own certificate
compile_catalog() {
  local name=$1 certname=$2
  $engine exec "$name" bash -c "
    e=/etc/puppetlabs/code/environments/smoketest/manifests
    mkdir -p \$e
    echo 'node default { notify { \"smoke\": } cron { \"smoke\": command => \"/bin/true\", hour => 3 } }' > \$e/site.pp
    d=\$(puppet config print ssldir)
    curl -s --resolve $certname:8140:127.0.0.1 \
      --cert \$d/certs/$certname.pem --key \$d/private_keys/$certname.pem --cacert \$d/certs/ca.pem \
      'https://$certname:8140/puppet/v3/catalog/$certname?environment=smoketest'" | grep -q '"type":"Cron"'
}

echo "== image: $image (engine: $engine)"

# 1. The image must not contain keys or certificates (the CDS build stage boots the server once)
if $engine run --rm --entrypoint bash "$image" -c '! find /etc/puppetlabs /opt/puppetlabs /usr/share/openvox-seed -name "*.pem" 2>/dev/null | grep -q .'; then
  pass "no keys or certificates baked into the image"
else
  fail "image contains .pem files"
fi

# 2. Runtime identity: non-root, high UID
uid=$($engine run --rm --entrypoint id "$image" -u)
if [ "$uid" -ge 10000 ]; then pass "runs as UID $uid (>= 10000)"; else fail "runs as UID $uid"; fi

# 3. Plain run (like the old `podman run --name openvox --hostname openvox ...`)
$engine run -d --name "$prefix-plain" --hostname openvox -e USE_OPENVOXDB=false -e CA_HOSTNAME=openvox "$image" >/dev/null
if wait_running "$prefix-plain"; then pass "server starts (plain run)"; else fail "server did not start (plain run)"; fi
if compile_catalog "$prefix-plain" openvox; then pass "catalog compiles (incl. vendored Cron type)"; else fail "catalog compilation"; fi

# 4. Bundled CLI tools
$engine exec "$prefix-plain" puppetserver ca list --all 2>&1 | grep -q "openvox" && pass "puppetserver ca list" || fail "puppetserver ca list"
$engine exec "$prefix-plain" bash -c 'cd /tmp && eyaml createkeys >/dev/null 2>&1 && echo -n s3cret | eyaml encrypt --stdin --pkcs7-public-key=keys/public_key.pkcs7.pem -o string | eyaml decrypt --stdin --pkcs7-public-key=keys/public_key.pkcs7.pem --pkcs7-private-key=keys/private_key.pkcs7.pem' 2>/dev/null | grep -q s3cret && pass "eyaml encrypt/decrypt" || fail "eyaml"
if $engine exec "$prefix-plain" bash -c 'command -v r10k' >/dev/null 2>&1; then
  $engine exec "$prefix-plain" bash -c 'r10k version && git --version' >/dev/null 2>&1 && pass "r10k + git" || fail "r10k + git"
fi

# 5. Graceful shutdown on SIGTERM
start=$(date +%s)
$engine stop -t 60 "$prefix-plain" >/dev/null
took=$(( $(date +%s) - start ))
code=$($engine inspect -f '{{.State.ExitCode}}' "$prefix-plain")
if [ "$code" = 143 ] && [ "$took" -lt 30 ]; then pass "SIGTERM shutdown in ${took}s (exit 143)"; else fail "SIGTERM shutdown: exit $code after ${took}s"; fi

# 6. Read-only root filesystem with empty writable mounts (what Kubernetes does)
t=rw,mode=0777
$engine run -d --name "$prefix-ro" --hostname openvox --read-only --user 64604:64604 -e USE_OPENVOXDB=false \
  --tmpfs /tmp:$t,exec --tmpfs /etc/puppetlabs:$t --tmpfs /opt/puppetlabs/server/data/puppetserver:$t \
  --tmpfs /opt/puppetlabs/puppet/cache:$t --tmpfs /var/log/puppetlabs:$t \
  --tmpfs /run/puppetlabs:$t --tmpfs /run/openvox:$t "$image" >/dev/null
if wait_running "$prefix-ro"; then pass "server starts with read-only root"; else fail "read-only root start"; fi
$engine exec "$prefix-ro" touch /usr/ro-test 2>/dev/null && fail "root filesystem is writable" || pass "root filesystem is read-only"
compile_catalog "$prefix-ro" openvox && pass "catalog compiles with read-only root" || fail "catalog with read-only root"

# 7. Migration: CA created by the old image must be reused unchanged, stay writable, and survive
#    a rollback. The ownership steps are exactly the ones AGENT.md runs in the cluster, using the
#    OLD image as a root maintenance container (it is already approved and contains tar).
if [ -n "$old_image" ]; then
  echo "== migration from $old_image"
  old_run() { $engine run -d --name "$prefix-old" --hostname openvox -e USE_OPENVOXDB=false -e CA_HOSTNAME=openvox \
    -v "$prefix-etc:/etc/puppetlabs" "$old_image" >/dev/null; }
  maint() { $engine run --rm --user 0 --entrypoint bash -v "$prefix-etc:/etc/puppetlabs" "$old_image" -c "$1"; }
  ca_fp() { $engine exec "$1" bash -c 'openssl x509 -noout -fingerprint -sha256 -in /etc/puppetlabs/puppetserver/ca/ca_crt.pem'; }
  sign() {  # sign a new certificate; prints the output on failure
    local out
    if out=$($engine exec "$1" puppetserver ca generate --certname "$2" 2>&1) \
       && $engine exec "$1" test -f "/etc/puppetlabs/puppetserver/ca/signed/$2.pem"; then
      pass "$3"
    else
      fail "$3:"; echo "$out" | sed 's/^/      /'
    fi
  }

  $engine volume create "$prefix-etc" >/dev/null
  old_run
  if wait_running "$prefix-old"; then pass "old image starts"; else fail "old image did not start"; fi
  fp_old=$(ca_fp "$prefix-old")
  $engine rm -f "$prefix-old" >/dev/null

  # Cutover step: hand the volume to the new runtime user (Kubernetes fsGroup alone is NOT enough:
  # the CA copies each file's owner when rewriting it, which a non-root user can't do for UID 999)
  maint 'chown -R 64604:64604 /etc/puppetlabs'

  $engine run -d --name "$prefix-new" --hostname openvox --user 64604:64604 -e USE_OPENVOXDB=false -e CA_HOSTNAME=openvox \
    -v "$prefix-etc:/etc/puppetlabs" "$image" >/dev/null
  if wait_running "$prefix-new"; then pass "new image starts on the old volume"; else fail "new image on old volume"; fi
  fp_new=$(ca_fp "$prefix-new")
  if [ -n "$fp_old" ] && [ "$fp_old" = "$fp_new" ]; then pass "CA kept ($fp_new)"; else fail "CA changed: '$fp_old' -> '$fp_new'"; fi
  compile_catalog "$prefix-new" openvox && pass "catalog compiles with migrated certificates" || fail "catalog after migration"
  sign "$prefix-new" migrated-test.example.com "new image signs certificates with the migrated CA"
  $engine rm -f "$prefix-new" >/dev/null

  # Rollback step: give the volume back to the old image's puppet user (UID/GID 999)
  maint 'chown -R 999:999 /etc/puppetlabs'
  old_run
  if wait_running "$prefix-old"; then pass "rollback: old image starts on the migrated volume"; else fail "rollback: old image start"; fi
  [ "$(ca_fp "$prefix-old")" = "$fp_old" ] && pass "rollback: CA unchanged" || fail "rollback: CA changed"
  $engine exec "$prefix-old" test -f /etc/puppetlabs/puppetserver/ca/signed/migrated-test.example.com.pem \
    && pass "rollback: certificate signed by the new image is still there" || fail "rollback: certificate missing"
  sign "$prefix-old" rollback-test.example.com "rollback: old image can still sign"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$failures TEST(S) FAILED"; fi
exit "$failures"
