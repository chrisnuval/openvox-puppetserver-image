#!/bin/bash
# Final stage (as root): runtime user, the release adjustments the upstream image makes, permissions,
# and pristine copies of the writable dirs.
set -euo pipefail
set -x

uid=$OPENVOX_USER_UID gid=$OPENVOX_USER_GID
data=/opt/puppetlabs/server/data/puppetdb

# No shadow-utils in ubi-minimal; the entries are simple enough to write directly
echo "puppetdb:x:${gid}:" >>/etc/group
echo "puppetdb:x:${uid}:${gid}:OpenVoxDB:${data}:/sbin/nologin" >>/etc/passwd

# Same as upstream prep_release_container.sh: run as any UID, HOCON config instead of the .ini
# files, no restart-file handling
sed -i 's/^ *USER="puppetdb"/USER=""/' /etc/default/puppetdb
rm -f /etc/puppetlabs/puppetdb/conf.d/database.ini /etc/puppetlabs/puppetdb/conf.d/config.ini
sed -i /init_restart_file/d /opt/puppetlabs/server/apps/puppetdb/cli/apps/foreground

mapfile -t writable < /usr/local/share/openvox/writable-dirs
for d in "${writable[@]}"; do mkdir -p "$d"; done
mkdir -p "$LOGDIR" "$SSLDIR" /run/puppetlabs/puppetdb /var/log/puppetlabs/puppetdb

chmod -R a+rX /opt/puppetlabs /etc/puppetlabs
chmod 0755 /container-entrypoint.sh /container-entrypoint.d/*.sh /healthcheck.sh /ssl.sh /wtfc.sh /usr/local/bin/pg_isready /usr/local/bin/forward-signals

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
