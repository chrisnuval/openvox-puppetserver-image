# OpenVox Server on Red Hat UBI (9 by default; UBI_MAJOR=10 also works).
#
# Java, Ruby, curl and OpenSSL come from Red Hat's RPMs (patched through UBI updates) instead of
# the openvox-agent all-in-one package, which vendors its own copies. Runs as UID 64604 / GID 0
# and supports a read-only root filesystem (see README: writable paths).
#
# Build:  podman build --format docker -t openvox-server-ubi:8.17.0 .
#   UBI 10: --build-arg UBI_MAJOR=10 --build-arg UBI_TAG=10.2   (amd64 needs x86-64-v3 / AVX2 CPUs)
#   Internal mirror: --build-arg UBI_REGISTRY=registry.example.com/redhat
# After changing any version below, run scripts/update-checksums.sh.

ARG UBI_REGISTRY=registry.access.redhat.com
ARG UBI_MAJOR=9
ARG UBI_TAG=9.8

################################################################################
FROM ${UBI_REGISTRY}/ubi${UBI_MAJOR}/ubi:${UBI_TAG} AS build

ARG UBI_MAJOR

# renovate: datasource=custom.voxpupuli-artifacts depName=openvox-server
ARG OPENVOXSERVER_VERSION=8.17.0
# renovate: datasource=custom.voxpupuli-artifacts depName=openvoxdb
ARG OPENVOXDB_VERSION=8.17.0
# Commit of OpenVoxProject/container-openvoxserver that built the upstream 8.17.0 image
ARG UPSTREAM_CONTAINER_REF=d51a22173a6de6e21731ee8e3c06d5d9f9dd8166
ARG VENDOR_MODULES="augeas_core:2.0.1 cron_core:2.0.3 host_core:2.0.1 mount_core:2.0.1 scheduled_task:5.0.0 selinux_core:2.0.1 sshkeys_core:3.0.2 yumrepo_core:3.0.1 zfs_core:2.0.1 zone_core:2.0.2"
ARG RUBYGEM_OPENVOX=8.31.0
ARG RUBYGEM_OPENVOXSERVER_CA=3.3.0
ARG RUBYGEM_HIERA_EYAML=5.0.1
ARG RUBYGEM_HOCON=1.4.0
ARG RUBYGEM_R10K=5.0.3
# r10k deploys code from git inside the container; set to false to leave out r10k and git
ARG WITH_R10K=true

# UBI 9's default Ruby is 3.0; the ruby:3.3 module stream matches what OpenVox is built against
RUN if [ "$UBI_MAJOR" = 9 ]; then dnf module enable -y ruby:3.3; fi \
    && dnf install -y --nodocs --setopt=install_weak_deps=False \
      java-21-openjdk-headless ruby ruby-devel rubygems gcc make redhat-rpm-config \
      findutils gzip tar which \
    && dnf clean all

COPY build/ /build/
RUN /build/install-openvox.sh

################################################################################
FROM ${UBI_REGISTRY}/ubi${UBI_MAJOR}/ubi-minimal:${UBI_TAG} AS app

ARG UBI_REGISTRY
ARG UBI_MAJOR
ARG UBI_TAG
ARG OPENVOXSERVER_VERSION=8.17.0
ARG WITH_R10K=true
ARG OPENVOX_USER_UID=64604
ARG OPENVOX_USER_GID=64604

LABEL org.opencontainers.image.title="OpenVox Server (UBI ${UBI_MAJOR})" \
      org.opencontainers.image.version="${OPENVOXSERVER_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0 AND AGPL-3.0-only" \
      org.opencontainers.image.base.name="${UBI_REGISTRY}/ubi${UBI_MAJOR}/ubi-minimal:${UBI_TAG}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Packages a headless server never uses at runtime, removed after install to cut scanner findings
# (UBI 9: about 160 of them). Java pulls in cups-libs/avahi-libs (printing) and, through
# crypto-policies-scripts, python3; the package manager isn't needed once the image is built.
# The RPM database stays, so scanners still see every remaining package.
ARG REMOVE_UNUSED_RPMS=true
ARG UNUSED_RPMS="python3 python3-libs python3-pip-wheel python3-setuptools-wheel crypto-policies-scripts cups-libs avahi-libs microdnf libdnf librepo libsolv libmodulemd json-glib librhsm gpgme gnupg2 libpeas libusbx libassuan libksba npth"

# curl is already in ubi-minimal (curl-minimal on UBI 9); installing "curl" there would conflict.
# hadolint ignore=SC2046  # the optional git-core word is meant to split
RUN if [ "$UBI_MAJOR" = 9 ]; then microdnf module enable -y ruby:3.3; fi \
    && microdnf install -y --nodocs --setopt=install_weak_deps=0 \
      java-21-openjdk-headless ruby rubygems rubygem-io-console \
      bash openssl procps-ng hostname findutils which \
      $([ "$WITH_R10K" = true ] && echo git-core) \
    && microdnf upgrade -y --nodocs \
    && microdnf clean all \
    && rm -rf /var/cache/yum /var/lib/dnf/history* \
    && if [ "$REMOVE_UNUSED_RPMS" = true ]; then \
         rpm -e --nodeps $(rpm -q --qf '%{NAME}\n' $UNUSED_RPMS | grep -v 'not installed'); \
       fi

# Settings read by the upstream entrypoint scripts (same names and defaults as the upstream image)
ENV AUTOSIGN=true \
    CA_ALLOW_SUBJECT_ALT_NAMES=false \
    CA_ENABLED=true \
    CA_TTL=157680000 \
    CA_HOSTNAME=puppet \
    CA_PORT=8140 \
    CERTNAME="" \
    CSR_ATTRIBUTES='{}' \
    DNS_ALT_NAMES="" \
    ENVIRONMENTPATH=/etc/puppetlabs/code/environments \
    HIERACONFIG='$confdir/hiera.yaml' \
    INTERMEDIATE_CA_BUNDLE=/etc/puppetlabs/intermediate/ca.pem \
    INTERMEDIATE_CA_KEY=/etc/puppetlabs/intermediate/key.pem \
    INTERMEDIATE_CA=false \
    INTERMEDIATE_CRL_CHAIN=/etc/puppetlabs/intermediate/crl.pem \
    LOGDIR=/var/log/puppetlabs/puppetserver \
    OPENVOX_REPORTS="puppetdb" \
    OPENVOX_STORECONFIGS_BACKEND="puppetdb" \
    OPENVOX_STORECONFIGS=true \
    OPENVOX_USER_UID=${OPENVOX_USER_UID} \
    OPENVOX_USER_GID=${OPENVOX_USER_GID} \
    OPENVOXDB_SERVER_URLS=https://openvoxdb:8081 \
    OPENVOXSERVER_ENABLE_ENV_CACHE_DEL_API=true \
    OPENVOXSERVER_ENVIRONMENT_TIMEOUT=unlimited \
    OPENVOXSERVER_GRAPHITE_EXPORTER_ENABLED=false \
    OPENVOXSERVER_GRAPHITE_HOST=exporter \
    OPENVOXSERVER_GRAPHITE_PORT=9109 \
    OPENVOXSERVER_HOSTNAME="" \
    OPENVOXSERVER_JAVA_ARGS="-Xms1024m -Xmx1024m -XX:SharedArchiveFile=/opt/puppetlabs/server/apps/puppetserver/puppetserver.jsa" \
    OPENVOXSERVER_MAX_ACTIVE_INSTANCES=1 \
    OPENVOXSERVER_MAX_REQUESTS_PER_INSTANCE=0 \
    OPENVOXSERVER_PORT=8140 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/opt/puppetlabs/server/bin:/opt/puppetlabs/puppet/bin:/opt/puppetlabs/bin \
    USE_OPENVOXDB=true \
    HOME=/opt/puppetlabs/server/data/puppetserver

COPY --from=build /usr/local /usr/local
COPY --from=build /etc/puppetlabs /etc/puppetlabs
COPY --from=build /opt/puppetlabs /opt/puppetlabs
COPY --from=build /var/log/puppetlabs /var/log/puppetlabs
COPY --from=build /upstream/ /
COPY rootfs/ /
COPY build/finalize-image.sh /usr/local/libexec/openvox/finalize-image.sh
RUN /usr/local/libexec/openvox/finalize-image.sh

USER ${OPENVOX_USER_UID}:0

################################################################################
# Create a class-data-sharing archive for faster JVM startup. This stage boots the server once;
# only the archive is kept, so the CA and certificates it generates never reach the final image.
FROM app AS cds
ARG CDS_TIMEOUT=90
RUN OPENVOXSERVER_JAVA_ARGS="-Xms1024m -Xmx1024m -XX:ArchiveClassesAtExit=/tmp/puppetserver.jsa -Xlog:cds=off" \
    USE_OPENVOXDB=false \
    timeout --preserve-status "${CDS_TIMEOUT}" /container-entrypoint.sh foreground || [ $? -eq 143 ]

################################################################################
FROM app AS final
COPY --from=cds /tmp/puppetserver.jsa /opt/puppetlabs/server/apps/puppetserver/puppetserver.jsa

# Kubernetes ignores HEALTHCHECK and uses the probes in k8s/openvox-server.yaml instead
HEALTHCHECK --interval=20s --timeout=15s --retries=12 --start-period=3m CMD ["/healthcheck.sh"]

EXPOSE 8140

ENTRYPOINT ["/container-entrypoint.sh"]
CMD ["foreground"]
