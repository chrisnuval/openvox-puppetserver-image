#!/bin/bash
# Replaces the upstream script of the same name, which appends to a file inside the application
# directory (read-only here) and edits puppetdb.conf with an all-in-one-agent hocon binary that
# this image doesn't have. Same variable, same effect: the allowlist file lives in the writable
# config directory and puppetdb.conf points at it.
conf=/etc/puppetlabs/puppetdb/conf.d/puppetdb.conf
list=/etc/puppetlabs/puppetdb/certificate-allowlist

if [ -n "$OPENVOXDB_CERTIFICATE_ALLOWLIST" ]; then
  tr ',' '\n' <<<"$OPENVOXDB_CERTIFICATE_ALLOWLIST" | sed 's/^ *//; s/ *$//; /^$/d' > "$list"
  cat > "$conf" <<HOCON
puppetdb: {
  disable-update-checking: 'true'
  certificate-allowlist: "$list"
}
HOCON
elif [ -w "$conf" ] && grep -q certificate-allowlist "$conf"; then
  # allowlist removed since the last start (config on a persistent volume)
  printf "puppetdb: {\n  disable-update-checking: 'true'\n}\n" > "$conf"
fi
