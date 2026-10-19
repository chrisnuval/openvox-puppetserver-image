#!/bin/bash
# Functional tests for the OpenVoxDB image, together with PostgreSQL and the server image.
# Works with podman (default) or docker.
#
#   scripts/openvoxdb-test.sh <db-image> <server-image> [<old-db-image> <old-server-image>]
#     ENGINE=docker scripts/openvoxdb-test.sh openvoxdb-ubi:8.17.0 openvox-server-ubi:8.17.0 \
#       ghcr.io/voxpupuli/puppetdb:8.8.1-v1.7.0 ghcr.io/openvoxproject/openvoxserver:8.8.1-v1.0.0
#
# With the old images it also tests the migration from the running PuppetDB (old env names,
# files owned by 999) and the rollback (database restored from pg_dump).
# PG_IMAGE (default docker.io/library/postgres:16) is only a test fixture.
# Prints PASS/FAIL per test; exits non-zero if anything failed.

set -uo pipefail
db_image=${1:?usage: openvoxdb-test.sh <db-image> <server-image> [<old-db-image> <old-server-image>]}
server_image=${2:?server image}
old_db_image=${3:-} old_server_image=${4:-}
engine=${ENGINE:-podman}
pg_image=${PG_IMAGE:-docker.io/library/postgres:16}
p=ovxdb-test-$$
failures=0
t=rw,mode=0777

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
cleanup() {
  $engine rm -f $($engine ps -aq --filter "name=^$p-") >/dev/null 2>&1
  $engine volume rm -f "$p-data" "$p-mdata" >/dev/null 2>&1
  $engine network rm "$p" >/dev/null 2>&1
}
trap cleanup EXIT
$engine network create "$p" >/dev/null

# PostgreSQL with the pg_trgm extension OpenVoxDB requires (normally created by the DB admin
# or the chart's init script)
start_pg() {
  local name=$1
  $engine run -d --name "$name" --network "$p" --network-alias postgres \
    -e POSTGRES_USER=puppetdb -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=puppetdb "$pg_image" >/dev/null
  for _ in $(seq 1 30); do
    $engine exec "$name" pg_isready -U puppetdb -d puppetdb -q 2>/dev/null \
      && $engine exec "$name" psql -U puppetdb -d puppetdb -qc 'CREATE EXTENSION IF NOT EXISTS pg_trgm' >/dev/null 2>&1 \
      && return 0
    sleep 2
  done
  return 1
}
wait_server() {
  local name=$1
  for _ in $(seq 1 60); do
    [ "$($engine exec "$name" curl -sk https://localhost:8140/status/v1/simple 2>/dev/null)" = running ] && return 0
    sleep 5
  done
  $engine logs "$name" 2>&1 | tail -20; return 1
}
wait_db() {
  local name=$1
  for _ in $(seq 1 60); do
    $engine exec "$name" curl -s http://localhost:8080/status/v1/services/puppetdb-status 2>/dev/null \
      | grep -q '"state":"running"' && return 0
    [ "$($engine inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = true ] || break
    sleep 5
  done
  $engine logs "$name" 2>&1 | grep -v '^\.' | tail -20; return 1
}
# A throwaway agent (the server image has the puppet CLI); state in /tmp
agent_run() {
  local out rc
  out=$($engine run --rm --network "$p" --entrypoint puppet "$server_image" agent -t --server puppet \
    --certname "$1" --vardir /tmp/v --publicdir /tmp/v/public --ssldir /tmp/v/ssl --rundir /tmp/v/run \
    --logdir /tmp/v/log --confdir /tmp/v/etc --codedir /tmp/v/code 2>&1)
  rc=$?   # --detailed-exitcodes: 0 no changes, 2 changes; 1, 4, 6 failures
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then echo "$out" | tail -5 | sed 's/^/      agent: /'; return 1; fi
}
# Is <certname> known to the DB with a stored report? (queried on the DB's plain-HTTP port)
db_has_node() {
  local name=$1 node=$2
  for _ in $(seq 1 12); do
    $engine exec "$name" curl -s "http://localhost:8080/pdb/query/v4/nodes/$node" 2>/dev/null \
      | grep -qE '"latest_report_hash" *: *"[0-9a-f]' && return 0
    sleep 5
  done
  return 1
}
cert_fp() { $engine exec "$1" sh -c 'openssl x509 -noout -fingerprint -sha256 -in "$SSLDIR/certs/server.crt"' 2>/dev/null; }
# OpenVoxDB with a read-only root: only the data dir is a volume, the rest is scratch
run_new_db() {
  local name=$1 alias=$2 vol=$3; shift 3
  $engine run -d --name "$name" --network "$p" --hostname "$alias" --network-alias "$alias" --read-only \
    --tmpfs /tmp:$t,exec --tmpfs /etc/puppetlabs/puppetdb:$t --tmpfs /var/log/puppetlabs:$t --tmpfs /run/puppetlabs:$t \
    -v "$vol:/opt/puppetlabs/server/data/puppetdb" -e OPENVOXSERVER_HOSTNAME=puppet "$@" "$db_image" >/dev/null
}

echo "== OpenVoxDB image: $db_image, server: $server_image (engine: $engine)"

# 1. Image basics
if $engine run --rm --entrypoint bash "$db_image" -c '! find /etc/puppetlabs /opt/puppetlabs /usr/share/openvox-seed \( -name "*.pem" -o -name "*.crt" -o -name "*.key" \) | grep -q .'; then
  pass "no keys or certificates baked into the image"
else
  fail "image contains certificates or keys"
fi
uid=$($engine run --rm --entrypoint id "$db_image" -u)
[ "$uid" -ge 10000 ] 2>/dev/null && pass "runs as UID $uid (>= 10000)" || fail "runs as UID $uid"

# 2. New stack: PostgreSQL + new server + new OpenVoxDB (read-only root)
db_env=(-e OPENVOXDB_POSTGRES_DATABASE=puppetdb -e OPENVOXDB_POSTGRES_USER=puppetdb -e OPENVOXDB_POSTGRES_PASSWORD=pw)
start_pg "$p-pg" || fail "PostgreSQL fixture"
$engine run -d --name "$p-srv" --network "$p" --hostname puppet --network-alias puppet \
  -e DNS_ALT_NAMES=puppet -e OPENVOXDB_SERVER_URLS=https://openvoxdb:8081 "$server_image" >/dev/null
wait_server "$p-srv" || fail "server start"
$engine volume create "$p-data" >/dev/null
run_new_db "$p-db" openvoxdb "$p-data" "${db_env[@]}"
if wait_db "$p-db"; then pass "OpenVoxDB starts with read-only root (cert from the server CA)"; else fail "OpenVoxDB start"; fi
$engine exec "$p-db" touch /usr/ro-test 2>/dev/null && fail "root filesystem is writable" || pass "root filesystem is read-only"
$engine exec "$p-db" /healthcheck.sh >/dev/null 2>&1 && pass "healthcheck script" || fail "healthcheck script"
if agent_run node1.example && db_has_node "$p-db" node1.example; then
  pass "agent run: facts, catalog and report stored via the server (TLS)"
else
  fail "agent run data not in OpenVoxDB"
fi

# 3. Certificate allowlist (upstream script replaced: must work with a read-only root)
$engine rm -f "$p-db" >/dev/null
run_new_db "$p-db" openvoxdb "$p-data" "${db_env[@]}" -e OPENVOXDB_CERTIFICATE_ALLOWLIST=puppet
if wait_db "$p-db" && agent_run node2.example && db_has_node "$p-db" node2.example; then
  pass "certificate allowlist: allowed server can write"
else
  fail "certificate allowlist (allowed)"
fi
$engine rm -f "$p-db" >/dev/null
run_new_db "$p-db" openvoxdb "$p-data" "${db_env[@]}" -e OPENVOXDB_CERTIFICATE_ALLOWLIST=someone-else
wait_db "$p-db" >/dev/null
agent_run node3.example
if ! $engine exec "$p-db" curl -s http://localhost:8080/pdb/query/v4/nodes/node3.example | grep -q latest_report_hash; then
  pass "certificate allowlist: other certificates are rejected"
else
  fail "certificate allowlist did not reject the server"
fi

# 3b. Password from a mounted file instead of the environment (CKV_K8S_35)
$engine rm -f "$p-db" >/dev/null
$engine run --rm -v "$p-data:/d" --user 0 --entrypoint bash "$db_image" -c 'printf pw > /d/pgpw-test; chmod 0400 /d/pgpw-test; chown 64604 /d/pgpw-test'
run_new_db "$p-db" openvoxdb "$p-data" -e OPENVOXDB_POSTGRES_DATABASE=puppetdb -e OPENVOXDB_POSTGRES_USER=puppetdb \
  -e OPENVOXDB_POSTGRES_PASSWORD_FILE=/opt/puppetlabs/server/data/puppetdb/pgpw-test
if wait_db "$p-db" && agent_run node4.example && db_has_node "$p-db" node4.example; then
  pass "PostgreSQL password from a file (OPENVOXDB_POSTGRES_PASSWORD_FILE)"
else
  fail "password file"
fi

# 4. Clean shutdown on SIGTERM
start=$(date +%s)
$engine stop -t 60 "$p-db" >/dev/null
secs=$(( $(date +%s) - start )); code=$($engine inspect -f '{{.State.ExitCode}}' "$p-db")
[ "$secs" -lt 30 ] && pass "SIGTERM shutdown in ${secs}s (exit $code)" || fail "SIGTERM shutdown took ${secs}s"
$engine rm -f "$p-db" "$p-srv" "$p-pg" >/dev/null

# 5. Migration from the old PuppetDB, and rollback
if [ -n "$old_db_image" ] && [ -n "$old_server_image" ]; then
  echo "== migration from $old_db_image (server $old_server_image)"
  start_pg "$p-mpg" || fail "PostgreSQL fixture"
  $engine run -d --name "$p-msrv" --network "$p" --hostname puppet --network-alias puppet \
    -e DNS_ALT_NAMES=puppet -e OPENVOXDB_SERVER_URLS=https://puppetdb:8081 "$old_server_image" >/dev/null
  wait_server "$p-msrv" || fail "old server start"
  $engine volume create "$p-mdata" >/dev/null
  old_db() {
    $engine run -d --name "$p-mold" --network "$p" --hostname puppetdb --network-alias puppetdb \
      -v "$p-mdata:/opt/puppetlabs/server/data/puppetdb" -e PUPPETSERVER_HOSTNAME=puppet \
      -e PUPPETDB_POSTGRES_HOSTNAME=postgres -e PUPPETDB_POSTGRES_DATABASE=puppetdb \
      -e PUPPETDB_USER=puppetdb -e PUPPETDB_PASSWORD=pw -e PUPPETDB_CERTIFICATE_ALLOWLIST=puppet "$old_db_image" >/dev/null
  }
  old_db
  wait_db "$p-mold" && pass "old PuppetDB starts" || fail "old PuppetDB start"
  agent_run old1.example && db_has_node "$p-mold" old1.example && pass "old setup stores agent data" || fail "old setup agent data"
  fp_old=$(cert_fp "$p-mold"); echo "      PuppetDB cert $fp_old"
  echo "      data volume owners: $($engine exec "$p-mold" stat -c '%u:%g %a' /opt/puppetlabs/server/data/puppetdb/certs/private_keys/server.key)"
  $engine exec "$p-mpg" pg_dump -U puppetdb -Fc -f /tmp/puppetdb.dump puppetdb && pass "pg_dump before migration" || fail "pg_dump"
  $engine stop -t 60 "$p-mold" >/dev/null

  # Without the ownership handover the new image cannot read the old key (KNOWLEDGE.md K2).
  # The old values are carried over under the new names (K16), including the allowlist: the
  # 8.8.1 image always enforces one (empty = nobody), OpenVoxDB only when it is set.
  mig_env=(-e CERTNAME=puppetdb -e OPENVOXDB_POSTGRES_DATABASE=puppetdb -e OPENVOXDB_POSTGRES_USER=puppetdb
           -e OPENVOXDB_POSTGRES_PASSWORD=pw -e OPENVOXDB_CERTIFICATE_ALLOWLIST=puppet)
  run_new_db "$p-mnew" puppetdb "$p-mdata" "${mig_env[@]}"
  if wait_db "$p-mnew" >/dev/null 2>&1; then
    fail "expected failure without ownership handover (files owned by 999) - it started anyway"
  else
    pass "without handover the new image fails as expected (999-owned key)"
  fi
  $engine rm -f "$p-mnew" >/dev/null

  # One-time handover with the old image as root, then the new image with the OLD names/values
  maint() { $engine run --rm --user 0 --entrypoint bash -v "$p-mdata:/data" "$old_db_image" -c "$1"; }
  maint 'chown -R 64604:64604 /data' && pass "data volume handed over to 64604" || fail "handover"
  run_new_db "$p-mnew" puppetdb "$p-mdata" "${mig_env[@]}"
  if wait_db "$p-mnew"; then pass "new OpenVoxDB starts on the migrated volume and database"; else fail "new OpenVoxDB on migrated data"; fi
  [ "$(cert_fp "$p-mnew")" = "$fp_old" ] && pass "PuppetDB certificate kept (no new certificate request)" || fail "certificate changed"
  db_has_node "$p-mnew" old1.example && pass "data from the old PuppetDB is present" || fail "old data missing"
  agent_run new1.example && db_has_node "$p-mnew" new1.example && pass "new agent data stored after migration" || fail "agent data after migration"
  $engine stop -t 60 "$p-mnew" >/dev/null

  # Rollback: restore the pre-migration dump (the schema was migrated forward), give the files back
  $engine exec "$p-mpg" sh -c 'dropdb -U puppetdb --force puppetdb_tmp 2>/dev/null; psql -U puppetdb -d postgres -qc "DROP DATABASE puppetdb WITH (FORCE)" && createdb -U puppetdb puppetdb && pg_restore -U puppetdb -d puppetdb /tmp/puppetdb.dump' >/dev/null \
    && pass "rollback: database restored from pg_dump" || fail "rollback: restore"
  maint 'chown -R 999:999 /data' >/dev/null
  $engine rm -f "$p-mold" >/dev/null
  old_db
  wait_db "$p-mold" && pass "rollback: old PuppetDB starts" || fail "rollback: old PuppetDB start"
  [ "$(cert_fp "$p-mold")" = "$fp_old" ] && pass "rollback: certificate unchanged" || fail "rollback: certificate changed"
  db_has_node "$p-mold" old1.example && pass "rollback: pre-migration data present" || fail "rollback: data missing"
fi

echo
if [ "$failures" -eq 0 ]; then echo "ALL OPENVOXDB TESTS PASSED"; else echo "$failures TEST(S) FAILED"; fi
exit "$failures"
