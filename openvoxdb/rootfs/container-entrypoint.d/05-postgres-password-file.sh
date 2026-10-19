#!/bin/bash
# Optional: read the PostgreSQL password from a file (a mounted Secret) instead of the
# OPENVOXDB_POSTGRES_PASSWORD environment variable (Checkov CKV_K8S_35: secrets as files).
#   OPENVOXDB_POSTGRES_PASSWORD_FILE=/run/secrets/openvoxdb/password
# Writes the password into conf.d/database.conf, which lives in the writable config directory
# (emptyDir in Kubernetes, rebuilt from the image at every start), readable only by this user.
set -euo pipefail
f=${OPENVOXDB_POSTGRES_PASSWORD_FILE:-}
[ -n "$f" ] || exit 0
[ -r "$f" ] || { echo "OPENVOXDB_POSTGRES_PASSWORD_FILE: cannot read $f" >&2; exit 1; }
conf=/etc/puppetlabs/puppetdb/conf.d/database.conf
umask 077
pw=$(cat "$f")
pw=${pw//\\/\\\\}; pw=${pw//\"/\\\"}   # HOCON quoted string: escape \ and "
PW=$pw awk '/^[[:space:]]*password:/ { print "  password: \"" ENVIRON["PW"] "\""; next } { print }' \
  "$conf" > "$conf.new"
mv "$conf.new" "$conf"
