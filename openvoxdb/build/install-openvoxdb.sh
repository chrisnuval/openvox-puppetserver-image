#!/bin/bash
# Builder stage: download and verify the OpenVoxDB tarball and the upstream image repo, then
# install with the upstream repo's own install script (the same steps its image uses).
set -euo pipefail
set -x

source /build/sources.sh
dl=/build/dl
mkdir -p "$dl"

while read -r url file; do
  curl -fsSL --retry 5 --retry-all-errors -o "$dl/$file" "$url"
  if ! grep -q "  $file\$" /build/checksums.sha256; then
    echo "No checksum for $file. Run scripts/update-checksums.sh after changing versions." >&2
    exit 1
  fi
done < <(db_sources)
(cd "$dl" && awk 'NR==FNR {want[$1]; next} ($2 in want)' <(ls) /build/checksums.sha256 | sha256sum -c -)

# Upstream image repo: install script and the files its image ships (entrypoint, ssl.sh, config)
tar -xzf "$dl/container-openvoxdb-${OPENVOXDB_UPSTREAM_REF}.tar.gz" -C /build
src="/build/container-openvoxdb-${OPENVOXDB_UPSTREAM_REF}/openvoxdb"

# prep_build_container.sh expects the tarball in / and installs from /puppetdb-<version>
cp "$dl/openvoxdb-${OPENVOXDB_VERSION}.tar.gz" /
OPENVOXDB_VERSION=$OPENVOXDB_VERSION bash "$src/prep_build_container.sh"
rm -rf "/openvoxdb-${OPENVOXDB_VERSION}.tar.gz" "/puppetdb-${OPENVOXDB_VERSION}"

mkdir -p /upstream
cp -a "$src/files/." /upstream/
