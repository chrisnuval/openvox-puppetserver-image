#!/bin/bash
# Every file the build downloads, as "<url> <filename>" lines. Sourced by the builder stage
# (download + verify) and by scripts/update-checksums.sh (regenerate build/checksums.sha256).
# Versions come from the Containerfile ARGs, passed in as environment variables.

sources() {
  local a=https://artifacts.voxpupuli.org gh=https://github.com/OpenVoxProject
  echo "$a/openvox-server/${OPENVOXSERVER_VERSION}/openvox-server-${OPENVOXSERVER_VERSION}.tar.gz openvox-server-${OPENVOXSERVER_VERSION}.tar.gz"
  echo "$a/openvoxdb/${OPENVOXDB_VERSION}/openvoxdb-${OPENVOXDB_VERSION}.tar.gz openvoxdb-${OPENVOXDB_VERSION}.tar.gz"
  # Entrypoint scripts from the upstream image repo (AGPL-3.0), used unmodified
  echo "$gh/container-openvoxserver/archive/${UPSTREAM_CONTAINER_REF}.tar.gz container-openvoxserver-${UPSTREAM_CONTAINER_REF}.tar.gz"
  local m
  for m in $VENDOR_MODULES; do  # "name:version" pairs
    echo "$gh/puppetlabs-${m%%:*}/archive/refs/tags/v${m#*:}.tar.gz puppetlabs-${m%%:*}-${m#*:}.tar.gz"
  done
}
