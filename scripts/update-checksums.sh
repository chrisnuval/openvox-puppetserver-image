#!/bin/bash
# Regenerate build/checksums.sha256 after changing a version ARG in the Containerfile.
# Extra server versions to allow via --build-arg: EXTRA_VERSIONS="9.1.0" scripts/update-checksums.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Export the Containerfile's ARG defaults (ARG NAME=value / ARG NAME="value")
while IFS='=' read -r name value; do
  export "$name=${value//\"/}"
done < <(sed -nE 's/^ARG ([A-Z0-9_]+)=(.*)$/\1=\2/p' Containerfile)
source build/sources.sh

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
list() {
  sources
  for v in ${EXTRA_VERSIONS:-}; do OPENVOXSERVER_VERSION=$v OPENVOXDB_VERSION=$v sources | head -2; done
}
list | sort -u | while read -r url file; do
  echo "fetching $file" >&2
  curl -fsSL --retry 5 --retry-all-errors -o "$tmp/$file" "$url"
done
(cd "$tmp" && sha256sum -- * 2>/dev/null || shasum -a 256 -- *) > build/checksums.sha256
cat build/checksums.sha256
