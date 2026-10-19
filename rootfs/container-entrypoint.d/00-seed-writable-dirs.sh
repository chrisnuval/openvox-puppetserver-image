#!/bin/bash
# Fill writable mounts (emptyDir, PVC, tmpfs) from the image's pristine copies, so the container
# can run with a read-only root filesystem. Existing files are never overwritten, so config and
# certificates on a persistent volume are kept; files new in an upgraded image are added.
#
# Mounts may sit at any depth: with a read-only root and volumes on /etc/puppetlabs/puppet and
# /etc/puppetlabs/puppetserver (the Helm chart's layout), /etc/puppetlabs itself is read-only but
# its mounted children are filled.
#
# Copies entry by entry rather than with `cp --update=none` (not in UBI 9's coreutils 8.32), and
# never touches a mount point itself, which belongs to root and can't be chmod-ed by this user.

set -e

seed=/usr/share/openvox-seed
while read -r d; do
  [ -d "$seed$d" ] || continue
  mkdir -p "$d" 2>/dev/null || true
  skipped=0
  while read -r p; do
    src="$seed$d/${p#./}" dst="$d/${p#./}"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      continue
    elif [ ! -w "$(dirname "$dst")" ]; then
      skipped=$((skipped + 1))   # parent is on the read-only root and not a volume
    elif [ -d "$src" ] && [ ! -L "$src" ]; then
      mkdir "$dst" && chmod --reference="$src" "$dst"
    else
      cp -P --preserve=mode,timestamps "$src" "$dst"
    fi
  done < <(cd "$seed$d" && find . -mindepth 1)
  if [ "$skipped" -gt 0 ]; then
    echo "NOTE: $skipped entries under $d not seeded (read-only, not on a volume)" >&2
  fi
done < /usr/local/share/openvox/writable-dirs
