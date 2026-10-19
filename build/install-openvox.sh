#!/bin/bash
# Builder stage: install OpenVox Server from the release tarball, plus every Ruby/JRuby gem it
# needs, so the final stage only copies files and never needs compilers or network access.
set -euo pipefail
set -x

source /build/sources.sh
dl=/build/dl
mkdir -p "$dl"

# --- download and verify every source ---------------------------------------------------------
while read -r url file; do
  curl -fsSL --retry 5 --retry-all-errors -o "$dl/$file" "$url"
  if ! grep -q "  $file\$" /build/checksums.sha256; then
    echo "No checksum for $file. Run scripts/update-checksums.sh after changing versions." >&2
    exit 1
  fi
done < <(sources)
(cd "$dl" && awk 'NR==FNR {want[$1]; next} ($2 in want)' <(ls) /build/checksums.sha256 | sha256sum -c -)

# --- OpenVox Server, using the tarball's own installer ----------------------------------------
tar -xzf "$dl/openvox-server-${OPENVOXSERVER_VERSION}.tar.gz" -C /build
cd "/build/puppetserver-${OPENVOXSERVER_VERSION}"
bash install.sh install

# JRuby gem homes live under apps/ (read-only at runtime). The data dir only gets symlinks to
# them, so the writable data volume stays small.
apps=/opt/puppetlabs/server/apps/puppetserver
data=/opt/puppetlabs/server/data/puppetserver
install -d -m 0755 "$apps/jruby-gems" "$apps/vendored-jruby-gems"
ln -s "$apps/jruby-gems" "$data/jruby-gems"
ln -s "$apps/vendored-jruby-gems" "$data/vendored-jruby-gems"
bash ext/build-scripts/install-vendored-gems.sh

# --- MRI (system Ruby) gems: the puppet/facter CLIs, `puppetserver ca`, hocon, r10k --------------
# Installed as root on RHEL these land in /usr/local/share/gems, binstubs in /usr/local/bin.
gems=("hocon:${RUBYGEM_HOCON}" "openvox:${RUBYGEM_OPENVOX}" "openvoxserver-ca:${RUBYGEM_OPENVOXSERVER_CA}" racc syslog)
[ "$WITH_R10K" = true ] && gems+=("r10k:${RUBYGEM_R10K}")
gem install --no-document "${gems[@]}"

# --- Upstream entrypoint scripts (unmodified) --------------------------------------------------
mkdir -p /upstream
tar -xzf "$dl/container-openvoxserver-${UPSTREAM_CONTAINER_REF}.tar.gz" -C /build
cp -a "/build/container-openvoxserver-${UPSTREAM_CONTAINER_REF}/openvoxserver/files/." /upstream/
rm /upstream/etc/default/puppetserver   # replaced by rootfs/etc/default/puppetserver
cp -a /upstream/etc/puppetlabs/. /etc/puppetlabs/
rm -rf /upstream/etc/puppetlabs

# --- Gems the server JVM loads (JRuby gem home) -------------------------------------------------
# `puppetserver gem` needs a defaults file; a minimal one is used during the build only.
mkdir -p /opt/puppetlabs/puppet/bin
for exe in puppet facter ruby gem irb erb; do  # irb/erb are separate RPMs on RHEL; link what exists
  if command -v "$exe" >/dev/null; then ln -s "$(command -v "$exe")" "/opt/puppetlabs/puppet/bin/$exe"; fi
done
cat >/etc/default/puppetserver <<EOF
JAVA_BIN="/usr/bin/java"
JAVA_ARGS="-Xms512m -Xmx512m"
USER=""
INSTALL_DIR="$apps"
CONFIG="/etc/puppetlabs/puppetserver/conf.d"
BOOTSTRAP_CONFIG="/etc/puppetlabs/puppetserver/services.d/,$apps/config/services.d/"
EOF
# upstream puppetserver.conf substitutes these from the environment
LOGDIR=/var/log/puppetlabs/puppetserver OPENVOXSERVER_MAX_ACTIVE_INSTANCES=1 OPENVOXSERVER_MAX_REQUESTS_PER_INSTANCE=0 \
  "$apps/bin/puppetserver" gem install --no-document "openvox:${RUBYGEM_OPENVOX}" "hiera-eyaml:${RUBYGEM_HIERA_EYAML}"
rm /etc/default/puppetserver   # the real one comes from rootfs/

# --- OpenVoxDB termini (puppetdb_query, storeconfigs, report processor) -------------------------
tar -xzf "$dl/openvoxdb-${OPENVOXDB_VERSION}.tar.gz" -C /build
vendor_ruby=/opt/puppetlabs/puppet/lib/ruby/vendor_ruby
install -d "$vendor_ruby"
cp -r "/build/puppetdb-${OPENVOXDB_VERSION}/puppet" "$vendor_ruby/"
# Puppet 4 functions load relative to puppet's own lib dir, so puppetdb_query must sit there too
cp -r "$vendor_ruby/puppet" "$apps/jruby-gems/gems/openvox-${RUBYGEM_OPENVOX}/lib/"

# --- Core type modules that used to ship inside the agent package -------------------------------
for m in $VENDOR_MODULES; do
  name=${m%%:*}
  install -d "/opt/puppetlabs/puppet/vendor_modules/$name"
  tar -xzf "$dl/puppetlabs-$name-${m#*:}.tar.gz" -C "/opt/puppetlabs/puppet/vendor_modules/$name" --strip-components 1
done

# --- CLI links ----------------------------------------------------------------------------------
[ "$WITH_R10K" = true ] && ln -s "$(command -v r10k)" /opt/puppetlabs/puppet/bin/r10k
for exe in puppet facter $([ "$WITH_R10K" = true ] && echo r10k); do
  ln -s "../puppet/bin/$exe" "/opt/puppetlabs/bin/$exe"
done

# eyaml CLI: hiera-eyaml lives only in the JRuby gem home; run it with system Ruby pointed there
cat >/opt/puppetlabs/puppet/bin/eyaml <<EOF
#!/bin/bash
# GEM_PATH replaces the default paths, so keep them (system gems such as io-console live there)
export GEM_PATH="$apps/jruby-gems:\$(gem env gempath)"
exec ruby $apps/jruby-gems/bin/eyaml "\$@"
EOF
chmod 0755 /opt/puppetlabs/puppet/bin/eyaml

# The foreground script's restart counter isn't used in containers
sed -i '/init_restart_file/d' "$apps/cli/apps/foreground"
