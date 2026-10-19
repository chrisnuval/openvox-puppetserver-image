# openvox-server-ubi

OpenVox Server built from scratch on **Red Hat UBI 9** (UBI 10 optional), as a hardened
replacement for `ghcr.io/openvoxproject/openvoxserver`.

**Migrating a running 8.8.1 server on Kubernetes? Follow [AGENT.md](AGENT.md)**: a step-by-step
runbook (written so an AI agent or a person can execute it) with build, tests, scans, staging
rehearsal, cutover and rollback.

[`KNOWLEDGE.md`](KNOWLEDGE.md) is the catalogue of every finding (K1–K16) with how to recognise
it in an unfamiliar chart or image repo, including PuppetDB/OpenVoxDB and PostgreSQL; AGENT.md
Path C uses it to analyse your own chart and image repos.
[`HANDOVER.md`](HANDOVER.md) is the checklist, with real sample output, for moving existing volumes
(CA, signed certificates, PuppetDB data) from the old images' UID 999 to the new UID 64604.

**For an agent:** give it this repository and `AGENT.md` as its instructions; AGENT.md tells it
when to read the other two.

- **No fixable vulnerabilities.** Java 21, Ruby 3.3, curl and OpenSSL come from Red Hat's RPMs,
  not from the openvox-agent all-in-one package (which vendors its own copies). No compilers, no
  package manager, no Python in the final image.
- **Kubernetes-ready.** Runs as UID 64604 / GID 0, works with a read-only root filesystem; the
  manifest passes Checkov with 0 failures once the image is pinned by digest, incl. CKV_K8S_9, _22, _40.
- **Drop-in.** Upstream entrypoint scripts are used unmodified, so every environment variable of
  the upstream image (`AUTOSIGN`, `DNS_ALT_NAMES`, `CA_*`, `OPENVOXDB_*`, ...) behaves the same.
- **Needs only podman** to build, test and scan.

## Scan comparison (Trivy 0.76.0, 2026-10-19)

| image | critical | high | medium | low | total | fixable |
|---|---|---|---|---|---|---|
| ghcr.io/openvoxproject/openvoxserver:8.8.1-v1.0.0 | 2 | 13 | 480 | 132 | 627 | 565 |
| ghcr.io/openvoxproject/openvoxserver:8.17.0 | 0 | 30 | 2709 | 86 | 2825 | 13 |
| **openvox-server-ubi:8.17.0, UBI 9.8 (default)** | 0 | 18 | 182 | 128 | 328 | **0** |
| openvox-server-ubi:8.17.0, UBI 10.2 | 0 | 1 | 0 | 0 | 1 | 0 |
| ghcr.io/voxpupuli/puppetdb:8.8.1-v1.7.0 | 0 | 5 | 495 | 162 | 662 | 592 |
| ghcr.io/openvoxproject/openvoxdb:8.15.0 | 0 | 22 | 175 | 85 | 282 | 230 |
| **openvoxdb-ubi:8.17.0, UBI 9.8** | 0 | 12 | 136 | 108 | 256 | **0** |

The remaining UBI 9 findings are in packages the server needs (curl, OpenSSL, Java, Ruby,
util-linux, expat) and are marked by Red Hat as `affected` / `will_not_fix` with no fix available.
They go away only with Red Hat updates (rebuild regularly) or with UBI 10, which needs
x86-64-v3 (AVX2) CPUs on amd64.

## Build

    podman build --format docker -t openvox-server-ubi:8.17.0 .
    # docker: docker build -f Containerfile -t openvox-server-ubi:8.17.0 .

| build arg | default | |
|---|---|---|
| `UBI_REGISTRY` | registry.access.redhat.com | internal mirror |
| `UBI_MAJOR` / `UBI_TAG` | 9 / 9.8 | `10` / `10.2` for UBI 10 (AVX2 required on amd64) |
| `WITH_R10K` | true | `false` leaves out r10k, git and ssh |
| `REMOVE_UNUSED_RPMS` | true | removes python3, printing libs and the package manager after install |
| `OPENVOXSERVER_VERSION` / `OPENVOXDB_VERSION` | 8.17.0 | 9.1.0 is also checksummed (also set `RUBYGEM_OPENVOX=9.1.0`) |
| `RUBYGEM_OPENVOX` | 8.31.0 | the puppet library |

Every download is verified against `build/checksums.sha256`; after changing a version run
`scripts/update-checksums.sh`.

## Test and scan

    scripts/smoke-test.sh openvox-server-ubi:8.17.0 [old-image-for-migration-test]
    scripts/scan.sh openvox-server-ubi:8.17.0          # OFFLINE=1 without docker.io access
    # ENGINE=docker for either script

`smoke-test.sh` checks: no keys baked in, non-root UID, start, catalog compilation, CA/eyaml/r10k
CLIs, SIGTERM shutdown, read-only root, and (with an old image) migration of an existing CA plus
rollback. `scan.sh` runs Trivy, Hadolint and Checkov (as containers if not installed), or a
built-in Checkov-compatible policy check using the image's own Ruby.

## Run

    podman run --name openvox --hostname openvox openvox-server-ubi:8.17.0

Read-only root filesystem (what Kubernetes does):

    podman run --read-only --hostname openvox \
      --tmpfs /tmp:exec --tmpfs /etc/puppetlabs --tmpfs /opt/puppetlabs/server/data/puppetserver \
      --tmpfs /opt/puppetlabs/puppet/cache --tmpfs /var/log/puppetlabs \
      --tmpfs /run/puppetlabs --tmpfs /run/openvox \
      openvox-server-ubi:8.17.0

### Writable paths
Listed in `rootfs/usr/local/share/openvox/writable-dirs`. At startup `00-seed-writable-dirs.sh`
fills each one from a pristine copy in the image, adding only missing files: empty volumes just
work, and config/certificates on persistent volumes are kept.
- `/etc/puppetlabs`: config, CA, certificates, code. **Persist this.**
- `/opt/puppetlabs/server/data/puppetserver`: vardir (reports, filebucket).
- `/opt/puppetlabs/puppet/cache`, `/var/log/puppetlabs`, `/run/puppetlabs`, `/run/openvox`: scratch.
- `/tmp` must allow exec (JRuby loads a native library from it); Kubernetes `emptyDir` does.

### Existing volumes from another image
The CA rewrites files keeping their owner. Volumes created by another image (e.g. the upstream
image, UID 999) must be handed over once with `chown -R 64604:64604` as root; Kubernetes `fsGroup`
alone is not enough (signing fails with "Operation not permitted"). AGENT.md has the procedure.

## Kubernetes

`k8s/openvox-server.yaml`: StatefulSet + Service + NetworkPolicy; non-root, read-only root, all
capabilities dropped, seccomp RuntimeDefault, startup/readiness/liveness probes on
`/status/v1/simple`, resource limits. For a migration use existing PVCs instead of
`volumeClaimTemplates` (AGENT.md Phase 6). `k8s/migration/` holds the one-time root maintenance
pod for backup/ownership/rollback; it is excluded from policy scans and must not stay deployed.

## OpenVoxDB

`openvoxdb/Containerfile` builds OpenVoxDB 8.17.0 the same way (release tarball on UBI 9 minimal,
Java 21, UID 64604, read-only root filesystem, upstream entrypoint scripts unmodified):

    podman build --format docker -f openvoxdb/Containerfile -t openvoxdb-ubi:8.17.0 .
    scripts/openvoxdb-test.sh openvoxdb-ubi:8.17.0 openvox-server-ubi:8.17.0 \
      ghcr.io/voxpupuli/puppetdb:8.8.1-v1.7.0 ghcr.io/openvoxproject/openvoxserver:8.8.1-v1.0.0

The test starts PostgreSQL, the server and OpenVoxDB, stores agent data, and with the old images
migrates a PuppetDB 8.8.1 volume and database and rolls back. Differences from the upstream
openvoxdb image:
- no default PostgreSQL password; set `OPENVOXDB_POSTGRES_PASSWORD`, or
  `OPENVOXDB_POSTGRES_PASSWORD_FILE` pointing at a mounted Secret (Checkov CKV_K8S_35);
- the certificate allowlist file lives in `/etc/puppetlabs/puppetdb` (writable), not in the app dir;
- `forward-signals` replaces dumb-init (not in UBI) for a clean stop on SIGTERM;
- `pg_isready` is a small TCP check instead of the PostgreSQL client package.
The database needs the `pg_trgm` extension (`CREATE EXTENSION pg_trgm;` as a superuser).
Kubernetes example: `k8s/openvoxdb.yaml`. Coming from PuppetDB 8.8.1: KNOWLEDGE.md K16.

## Helm (OpenVox chart)

Deployed with the [OpenVox Helm chart](https://github.com/OpenVoxProject/openvox-helm-chart)? Use
`helm/values-hardened.yaml` plus the post-renderer in `helm/post-render/` (see `helm/README.md`).
**Warning:** switching an existing release to `global.runAsNonRoot: true` makes the chart delete its
PVCs, CA included, unless the post-renderer is used; follow AGENT.md Path H.

## Differences from the upstream image
- UBI instead of Ubuntu/Alpine; Red Hat RPMs instead of the openvox-agent package.
- No `dumb-init` (not in UBI): the upstream entrypoint traps SIGTERM itself (tested).
- r10k uses its shell-git provider instead of the rugged gem.
- JRuby gem directories live under `apps/` (read-only); the data dir only holds symlinks.

## License
This repository's own files (Containerfile, scripts, manifests, Helm files, docs) are licensed
under the [Apache License 2.0](LICENSE). openvox-server itself is also Apache-2.0. The entrypoint scripts under `/container-entrypoint*`,
`/healthcheck.sh`, `/usr/local/bin/config_ini.rb`, `/usr/local/share/openvox/config_lib.sh` and
`/var/tmp/puppet` come unmodified from
[OpenVoxProject/container-openvoxserver](https://github.com/OpenVoxProject/container-openvoxserver),
which is **AGPL-3.0**. This repo's own files don't modify them. Check with your legal/compliance
team before distributing the image outside your organization.
