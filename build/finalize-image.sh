#!/bin/bash
# Final stage (as root): runtime user, permissions, and pristine copies of the writable dirs.
set -euo pipefail
set -x

uid=$OPENVOX_USER_UID gid=$OPENVOX_USER_GID
data=/opt/puppetlabs/server/data/puppetserver

# No shadow-utils in ubi-minimal; the entries are simple enough to write directly
echo "puppet:x:${gid}:" >>/etc/group
echo "puppet:x:${uid}:${gid}:OpenVox Server:${data}:/sbin/nologin" >>/etc/passwd

mapfile -t writable < /usr/local/share/openvox/writable-dirs
for d in "${writable[@]}"; do mkdir -p "$d"; done
mkdir -p /run/puppetlabs/puppetserver /etc/puppetlabs/code/environments/production/{manifests,modules}
install -d -m 0770 /etc/puppetlabs/puppet /etc/puppetlabs/puppet/ssl

# Non-root puppet CLIs use ~/.puppetlabs; point it at the system paths (HOME is the data dir)
mkdir -p "$data/.puppetlabs/var"
ln -sfn /etc/puppetlabs "$data/.puppetlabs/etc"
ln -sfn /opt/puppetlabs "$data/.puppetlabs/opt"
ln -sfn /var/log/puppetlabs "$data/.puppetlabs/var/log"
ln -sfn /run/puppetlabs "$data/.puppetlabs/var/run"

# The installers ran with umask 027; everything must be readable by the runtime user
chmod -R a+rX /opt/puppetlabs /usr/local /etc/puppetlabs

# Writable dirs: owned by the runtime user, group 0 with the same rights (OpenShift random UIDs)
for d in "${writable[@]}"; do
  chown -R "$uid:0" "$d"
  chmod -R g=u "$d"
  find "$d" -type d -exec chmod g+s {} +
done

# Pristine copies, used to fill empty volumes at startup (container-entrypoint.d/00-*)
for d in "${writable[@]}"; do
  mkdir -p "/usr/share/openvox-seed$d"
  cp -a "$d/." "/usr/share/openvox-seed$d/"
done

rm -f "$0"
