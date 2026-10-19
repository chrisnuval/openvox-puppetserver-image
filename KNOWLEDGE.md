# KNOWLEDGE.md: what we learned hardening OpenVox on Kubernetes

Companion to [AGENT.md](AGENT.md). AGENT.md is the procedure; this file is the **catalogue of
findings** behind it, written so an agent can recognise the same problems in a chart, image repo
or manifest it has never seen (for example a company fork of the OpenVox Helm chart) and apply the
same fix. Nothing here depends on seeing that code: each entry says **what to search for**, **why it
breaks**, and **the fix**.

Each entry is marked:
- **[tested]**: reproduced and fixed in the reference run (local k3s or container tests).
- **[inspected]**: read from the image or chart, not run end to end. Verify during the rehearsal.

---

## 1. Quick search list

Run these on the chart/manifest repo (adjust paths). Each hit maps to an entry below.

| Search (`grep -rnE ... templates/ values*.yaml`) | Finding |
|---|---|
| `runAsUser: *(0\|999\|1000\|1001)\b`, `runAsUser: \{\{` → check the value | K1 UID < 10000 (CKV_K8S_40) |
| `fsGroup` | K2 (fsGroup does not fix ownership) |
| `chown`, `chmod`, `CAP_CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `runAsNonRoot: false` in `initContainers` | K4 root init containers |
| `readOnlyRootFilesystem` (missing or `false`) | K3 (CKV_K8S_22) |
| `helm.sh/hook` in a template whose `kind:` is `PersistentVolumeClaim` | **K5 PVC deletion on upgrade** |
| `command:` / `args:` on the server or DB container | K6 entrypoint bypassed |
| `replicas:` inside `{{ if }}` only | K7 0 replicas after scale-down |
| `strategy:` / `updateStrategy` + `ReadWriteOnce` | K8, K10 |
| `r10k` sidecar | K9 |
| `image:` without `@sha256:`; `latest`, `-main` tags | K12 (CKV_K8S_43, 14) |
| `capabilities:` without `drop: [ALL]` | K12 (CKV_K8S_28/37) |
| `automountServiceAccountToken` missing | K12 (CKV_K8S_38) |
| `livenessProbe` / `readinessProbe` missing on any container | K12 (CKV_K8S_8/9) |
| `PUPPETDB_` env names, `USE_PUPPETSERVER` | K16 PuppetDB → OpenVoxDB renames |

Then render and scan (offline-capable): `helm template ... > rendered.yaml`, then
`scripts/k8s-policy-check.rb rendered.yaml` (runs with any Ruby, e.g. inside the new image) or the
Checkov container. Group failures **per workload** (server, DB, PostgreSQL, sidecars).

---

## 2. Findings and fixes

### K1. UID must be ≥ 10000 (CKV_K8S_40) [tested]
- Upstream images use UID **999** (`puppet` in the openvoxserver 8.8.1 image, `puppetdb` in the
  PuppetDB 8.8.1 image) or run as **root** and switch to 999 inside (`runuser`).
- Any `runAsUser` < 10000 fails CKV_K8S_40, including 999, 1000 (chart helper containers) and 1001 (Bitnami).
- Fix: run as **64604**, group 0 (image) or 64604 (chart `runAsGroup`/`fsGroup`); `runAsNonRoot: true`.
- The image must not try to switch users: the ezbake launcher calls `runuser`/`su` when `USER` in
  `/etc/default/<service>` names another user. Set `USER=""` (done for puppetserver in
  `rootfs/etc/default/puppetserver`; the upstream openvoxdb image does the same).

### K2. Existing volumes must be handed over once; fsGroup is not enough [tested]
- The old image leaves files owned by **999:999**. The CA rewrites files (serial, inventory) by
  creating a temp file and copying the old owner onto it; UID 64604 cannot set owner 999, so
  **signing fails with HTTP 500 `Operation not permitted`** while health checks pass.
- `fsGroup` is not enough: at mount Kubernetes re-groups the volume to the fsGroup and adds group
  read/write (observed: a `600` key became `660`), and every container in the pod gets that group.
  So **reading** works, but the CA's owner-preserving rewrites (and `chmod` by scripts) need the
  **owner**. Also, a sidecar left on 999 keeps working only thanks to fsGroup: check every container
  (HANDOVER.md step 6).
- Fix: one-time `chown -R 64604:64604` of every PVC, from a short-lived **root** pod running the
  **old** image (already approved in the cluster, has `chown`/`tar`), with the workload scaled to 0.
  `scripts/k8s-handover-volumes.sh` does this for a Deployment. Rollback: `chown -R 999:999`.
- PuppetDB **[tested]**: `/ssl.sh` sets `u=rw,g=,o=` on everything under
  `SSLDIR=/opt/puppetlabs/server/data/puppetdb/certs` (on the data PVC), so the private key is
  unreadable to any other UID (unless fsGroup re-groups it, see above). Reproduced without fsGroup: OpenVoxDB as 64604 on the 999-owned volume of
  `voxpupuli/puppetdb:8.8.1` fails to start; after `chown -R 64604:64604` it starts and keeps
  the certificate. The handover is mandatory for the PuppetDB PVC too. (The upstream openvoxdb
  MIGRATION.md suggests `chgrp -R 0` + `chmod -R g+rwX` instead; this repo uses and tested chown.)
- PostgreSQL **[inspected, general Postgres rule]**: the data directory must be owned by the running
  UID with mode 0700, or Postgres refuses to start. Changing its UID needs the same handover.
- Storage that refuses `chown` (NFS root squash): STOP; owner change on the storage side.
- Procedure with every check and real sample output: [HANDOVER.md](HANDOVER.md).

### K3. Read-only root filesystem (CKV_K8S_22) [tested]
- Every path the process or its entrypoint writes must be a volume. For the server image built here:
  `/etc/puppetlabs`, `/opt/puppetlabs/server/data/puppetserver`, `/opt/puppetlabs/puppet/cache`,
  `/var/log/puppetlabs`, `/run/puppetlabs`, `/run/openvox`, `/tmp`.
- `/tmp` must allow **exec** (JRuby loads a native library from it): `emptyDir` is fine; a
  `noexec` tmpfs gives `Cannot determine basic system flavour`.
- emptyDirs start empty: the image keeps pristine copies in `/usr/share/openvox-seed` and
  `00-seed-writable-dirs.sh` copies **missing** entries only (never overwrites PVC content, never
  touches mount points, works with nested mounts).
- OpenVoxDB (`openvoxdb/Containerfile`) writes: `/etc/puppetlabs/puppetdb` (the entrypoint
  `sed -i`s `conf.d/jetty.ini` to enable SSL; seeded emptyDir), `/opt/puppetlabs/server/data/puppetdb`
  (PVC: certificate, queue, logs), `/var/log/puppetlabs`, `/run/puppetlabs`, `/tmp`. Tested with
  `--read-only`.
- The upstream allowlist script appends to `/opt/puppetlabs/server/apps/puppetdb/certificate-allowlist`
  (inside the application dir) and calls an AIO-agent `hocon` binary; this image replaces it with a
  script that writes the list to `/etc/puppetlabs/puppetdb/certificate-allowlist` and points
  `puppetdb.conf` at it (tested: allowed certname writes, others are rejected).
- ConfigMap `subPath` mounts into `conf.d` (custom configs, metrics) stay read-only; fine as long as
  the entrypoint does not edit those same files (it edits `jetty.ini`, `puppetdb.conf`, `database.conf`).

### K4. Root init containers (CKV_K8S_40, also 22) [tested]
- Charts often `chown` volumes in a root init container at every start (`setup-dirs`,
  `perms-and-dirs`, ...). This is what fails CKV_K8S_40 even when the main container is non-root.
- Fix: remove them. Ownership is fixed once by K2; config seeding is done by the image itself (K3).
  Non-root helper init containers (wait-for-postgres, wait-for-server) are fine once they have
  UID ≥ 10000, read-only root, dropped capabilities and resources.

### K5. Helm hooks on PVCs delete data on upgrade [tested, the most dangerous finding]
- A PVC template with `helm.sh/hook: pre-install` is **not a release resource**. If an upgrade
  renders it as a hook while the previous revision had it as a normal resource (or vice versa),
  Helm treats it as removed and **deletes the PVC, including the CA**.
- In the public chart 11.0.0 this happens when `global.runAsNonRoot: true` is switched on; the
  PuppetDB PVC is a hook when `preGeneratedCertsJob` or `singleCA` is enabled. A fork may differ:
  compare the PVC annotations rendered for the **old** values with those for the **new** values.
- Fix: never render PVCs as hooks; add `helm.sh/resource-policy: keep` to every PVC template; and
  before any upgrade annotate the live PVCs:
  `kubectl annotate pvc -n <ns> -l app.kubernetes.io/instance=<rel> helm.sh/resource-policy=keep`.
  Verify PVC **UIDs** before/after the upgrade.
- Hook-only PVCs also mean "created on first install only": an upgrade that starts referencing one
  leaves the pod **Pending** (`persistentvolumeclaim ... not found`).

### K6. `command`/`args` overrides bypass the image entrypoint [tested]
- e.g. `exec puppetserver foreground`. The entrypoint is what applies env-var configuration
  (`DNS_ALT_NAMES`, autosign, CA settings, DB host) and seeds volumes (K3).
- Fix: no `command`/`args` on the server or DB container.

### K7. Replicas unset → stuck at 0 after a scale-down [tested]
- If `replicas` is only templated in some modes, `helm upgrade` does not restore it after the K2
  handover scaled the workload to 0. Fix: always render `replicas: 1` for single-instance workloads.

### K8. Switching to `Recreate` fails under server-side apply [tested]
- Helm 4 / SSA rejects `type: Recreate` while the live object still has `rollingUpdate`.
- Fix: keep `RollingUpdate` with `maxSurge: 0, maxUnavailable: 1` (same effect for one replica).

### K9. r10k sidecar and read-only root [tested]
- The r10k image's startup scripts append to `/etc/passwd`, write `~/.r10k_*` under `/home/puppet`
  and a default `/etc/puppetlabs/r10k/r10k.yaml`. With a read-only root every deploy fails.
- Fix: emptyDirs for `/tmp`, `/home/puppet`, `/etc/puppetlabs/r10k`; an `/etc/passwd` mounted via
  `subPath` from an emptyDir, written by a non-root init container from the same image (image
  passwd + `puppet:x:64604:0:r10k:/home/puppet:/bin/sh`). See `helm/post-render/post-render.sh`.

### K10. RollingUpdate with ReadWriteOnce volumes [tested]
- The new pod cannot mount the RWO PVC while the old one runs (multi-node: deadlock), and two CA
  servers must never run at once. Fix: K8 strategy (`maxSurge: 0`).

### K11. Where the Aqua/Trivy findings come from [tested]
- The 8.x images install the `openvox-agent`/`puppet-agent` all-in-one package, which **vendors
  Ruby, curl and OpenSSL** under `/opt/puppetlabs/puppet` (only fixed by a new agent release), on
  top of an Ubuntu base. Old Jetty (10.x) and gems (concurrent-ruby 1.2.3) are inside the app jars.
- Fix: install the application from the release **tarball** onto UBI with OS packages (RHEL-patched
  curl/OpenSSL/Ruby/Java), no AIO agent, remove unused RPMs. Target: 0 fixable, 0 critical.
- Reference Trivy counts (2026-10-19):

  | Image | Crit | High | Total | Fixable |
  |---|---|---|---|---|
  | `ghcr.io/openvoxproject/openvoxserver:8.8.1-v1.0.0` | 2 | 13 | 627 | 565 |
  | `ghcr.io/voxpupuli/puppetdb:8.8.1-v1.7.0` (Ubuntu 22.04, AIO agent, Java 17, curl 7.81 + vendored 8.10.1) | 0 | 5 | 662 | 592 |
  | `ghcr.io/openvoxproject/openvoxdb:8.15.0` (Ubuntu 26.04, Java 21) | 0 | 22 | 282 | 230 |
  | this repo's `openvox-server-ubi:8.17.0` (UBI 9) | 0 | 18 | 328 | **0** |
  | this repo's `openvoxdb-ubi:8.17.0` (UBI 9) | 0 | 12 | 256 | **0** |

  Upstream images are newer but **not** clean; building on UBI from the tarball gets both to 0 fixable.

### K12. Remaining Checkov checks and how they are met [tested]
| Check | Meaning | Fix |
|---|---|---|
| CKV_K8S_8 / 9 | liveness / readiness probe | server: `httpGet` HTTPS `/status/v1/simple` on 8140 (no client cert needed); DB: `httpGet` HTTP `/status/v1/services/puppetdb-status` on 8080; sidecars need their own (exec) probes |
| CKV_K8S_16, 20 | privileged, privilege escalation | `allowPrivilegeEscalation: false`, never `privileged` |
| CKV_K8S_23, 40 | root containers, low UID | `runAsNonRoot: true`, `runAsUser: 64604` (K1) |
| CKV_K8S_28, 37 | NET_RAW, capabilities | `capabilities.drop: [ALL]` on **every** container incl. init. (Checkov accepts `all` or `ALL`) |
| CKV_K8S_14, 15 | fixed tag, pull policy | no `latest`/empty tag; `imagePullPolicy: Always` |
| CKV_K8S_29, 30 | security context present | pod and container `securityContext` on every container |
| CKV_K8S_21 | default namespace | set `metadata.namespace` |
| CKV_K8S_31 | seccomp | pod `seccompProfile: {type: RuntimeDefault}` |
| CKV_K8S_38 | service account token | `automountServiceAccountToken: false` unless the pod calls the API |
| CKV_K8S_43 | image digest | `image: repo@sha256:...` (or `tag: "x@sha256:..."`), **all** images incl. sidecars/init |
| CKV_K8S_10–13 | requests/limits | set CPU/memory requests and limits on every container |
| CKV2_K8S_6 | NetworkPolicy | one per workload |
| CKV_K8S_35 | secrets as env vars | mount the Secret as a file; OpenVoxDB reads `OPENVOXDB_POSTGRES_PASSWORD_FILE` (this image; tested). Charts usually pass the DB password via `secretKeyRef` env, which fails this check |
- Exit criteria: compare **failed check IDs**, never pass counts (local Checkov and the container
  report 88 vs 89 passed for the same file).

### K13. Test pitfalls [tested]
- Server cert names: test with `curl --resolve <certname>:8140:127.0.0.1 https://<certname>:8140/...`.
- `puppetserver ca ...` needs `CA_HOSTNAME` (default `puppet`) to resolve inside the pod.
- `OPENVOXSERVER_ENVIRONMENT_TIMEOUT=unlimited` caches environments: use a new environment for tests.
- Catalog test requests send no facts: test manifests must not use `$facts`.
- `podman build --format docker` keeps `HEALTHCHECK`.
- `puppet agent` inside the server image fails (`Permission denied ... .puppetlabs/opt/puppet/public`):
  the server image is not an agent and its default agent dirs are read-only. For test agent runs use
  a throwaway container with `--vardir/--publicdir/--ssldir/--rundir/--logdir/--confdir/--codedir`
  under `/tmp` (see `scripts/openvoxdb-test.sh`).
- `puppet agent -t` exits **2** when it applied changes; treat 0 and 2 as success.
- PuppetDB single-object queries are pretty-printed (`"key" : "value"`); list queries are compact.

### K13b. Certificates for OpenVoxDB [tested]
- The CA autosigns only requests **without** alternative names unless the server has
  `CA_ALLOW_SUBJECT_ALT_NAMES=true`. An OpenVoxDB with `DNS_ALT_NAMES` set leaves an unsigned CSR
  and crash-loops with `unsigned CSR for '<certname>' already exists on CA`. The server connects to
  the certname, so name the DB Service like the certname and leave `DNS_ALT_NAMES` empty (or sign
  the CSR by hand: `puppetserver ca sign --certname <name>`).
- After a failed first start: `puppetserver ca clean --certname <name>` on the server and remove
  `certs/` on the DB volume, then start again.
- `puppetserver ca ...` inside the server pod needs `CA_HOSTNAME` to resolve: set it to the
  server's Service name (`k8s/openvox-server.yaml` does).

### K14. Image hosting and versions [tested]
- `ghcr.io/openvoxproject/openvoxserver` and `.../openvoxdb` are the OpenVox images;
  `ghcr.io/voxpupuli/puppetdb` / `puppetserver` are the older Perforce-based Vox Pupuli images.
  **There is no `openvoxdb:8.8.1`**: an "8.8.1 PuppetDB" is `ghcr.io/voxpupuli/puppetdb:8.8.1-*`.
- Release tarballs: `https://artifacts.voxpupuli.org/openvox-server/<v>/` and `.../openvoxdb/<v>/`
  (8.17.0 used here; checksums in `build/checksums.sha256`).

### K15. PostgreSQL [inspected]
- OpenVoxDB requires the `pg_trgm` extension (`CREATE EXTENSION pg_trgm;` as a superuser in the
  database); without it it stops with "PuppetDB requires the PostgreSQL `pg_trgm` extension" [tested].
- Bitnami PostgreSQL runs as 1001 (fails CKV_K8S_40) and supports arbitrary UIDs: set
  `runAsUser`/`fsGroup` ≥ 10000, `readOnlyRootFilesystem: true` with emptyDirs for `/tmp` and
  `/opt/bitnami/postgresql/tmp` (and conf if the chart writes it), then hand the data PVC over (K2).
- Alternatives: an existing managed/external PostgreSQL (removes the workload from scope), or the
  Red Hat `rhel9/postgresql-16` image (runs as 26: still needs a UID override).
- Back up with `pg_dump` before any change to the DB workload.

### K16. PuppetDB 8.8.1 (Vox Pupuli) → OpenVoxDB migration facts [tested]
| | `voxpupuli/puppetdb:8.8.1-v1.7.0` | `openvoxproject/openvoxdb:8.15.0` |
|---|---|---|
| Runs as | root, launcher `runuser` → `puppetdb` 999:999 | 64604:0, `USER=""` |
| Entrypoint | `dumb-init /docker-entrypoint.sh`, scripts in `/docker-entrypoint.d/` | `dumb-init /container-entrypoint.sh`, `/container-entrypoint.d/` |
| Env prefix | `PUPPETDB_*`, `USE_PUPPETSERVER`, `PUPPETSERVER_HOSTNAME/PORT` | `OPENVOXDB_*`, `USE_OPENVOXSERVER`, `OPENVOXSERVER_HOSTNAME/PORT` |
| DB defaults | db `puppetdb`, user `puppetdb` | db `openvoxdb`, user `openvoxdb` |
| `CERTNAME` default | `puppetdb` | `openvoxdb` |
| SSL files | `$SSLDIR/{certs/server.crt, private_keys/server.key, certs/ca.pem}`, `SSLDIR=/opt/puppetlabs/server/data/puppetdb/certs` | same paths |
| Data PVC | `/opt/puppetlabs/server/data/puppetdb` | same |
| Certificate allowlist | **always on**: with `PUPPETDB_CERTIFICATE_ALLOWLIST` empty the list is empty and every client, the server included, gets `403 ... doesnt appear in the certificate allowlist` | only when `OPENVOXDB_CERTIFICATE_ALLOWLIST` is set; otherwise any certificate from the CA is accepted |

Consequences:
- **Set every renamed variable explicitly** with the *old* values: `OPENVOXDB_POSTGRES_DATABASE=puppetdb`,
  `OPENVOXDB_POSTGRES_USER`, `..._PASSWORD`, `..._HOSTNAME`, TTLs,
  **`OPENVOXDB_CERTIFICATE_ALLOWLIST`** (a working 8.8.1 deployment must have
  `PUPPETDB_CERTIFICATE_ALLOWLIST` set; dropping it silently widens access to every certificate the
  CA signed), and
  **`CERTNAME=puppetdb`** (or whatever the old one was). Relying on the new defaults points the DB
  at an empty database and requests a new certificate under a new name.
- The upstream chart template uses `OPENVOX*` names; a fork running the 8.8.1 image uses
  `PUPPETDB_*`: update both the image and the env names in the same change.
- OpenVoxDB 8.17 runs on a PuppetDB 8.8.1 database and migrates the schema forward on start: **take
  a `pg_dump` first**; rollback = restore the dump into a fresh database, `chown -R 999:999` the
  volume, start 8.8.1 (tested by `scripts/openvoxdb-test.sh`: data and certificate intact).
- Tested end to end with `CERTNAME=puppetdb`, `OPENVOXDB_POSTGRES_DATABASE/USER` set to the old
  values: same certificate (no new CSR), old data present, new agent data stored.
- The server's `puppetdb.conf` / `OPENVOXDB_SERVER_URLS` must keep pointing at the same Service name.

---

## 3. What is in this repo vs what an own chart needs

| Concern | Public chart 11.0.0 | Own fork |
|---|---|---|
| Server image | `Containerfile` (this repo) | same |
| Server workload hardening | `helm/values-hardened.yaml` + `helm/post-render/` | apply K1–K10, K12 **in the templates**; the post-renderer depends on 11.0.0 names, use it only as a reference |
| Volume handover | `scripts/k8s-handover-volumes.sh` (Deployment) | same script if the workload is a Deployment and the server container is not named `r10k-*`; otherwise adapt the selection lines |
| Rehearsal | `scripts/helm-migration-test.sh` (labels `app.kubernetes.io/component=puppetserver`, `instance=<rel>`) | adapt `server_pod`, `pvc_uids` selectors to the fork's labels |
| DB image | `openvoxdb/Containerfile`, tests `scripts/openvoxdb-test.sh`, manifest `k8s/openvoxdb.yaml` | same; DB workload hardening in the templates following `k8s/openvoxdb.yaml` |
| PostgreSQL | not covered | K15 |

---

## 4. OpenVoxDB image specifics [tested]

| Topic | Upstream openvoxdb image | `openvoxdb-ubi` (this repo) | Why |
|---|---|---|---|
| PID 1 | `dumb-init` | `/usr/local/bin/forward-signals` | dumb-init is not in UBI; without a signal-forwarding PID 1 the launcher's bash ignores SIGTERM and pods wait the full grace period |
| DB password | default `openvoxdb` baked in | no default; env or `OPENVOXDB_POSTGRES_PASSWORD_FILE` | no secret in the image (Hadolint DL3064, Aqua), CKV_K8S_35 |
| `pg_isready` | PostgreSQL client package | TCP-check stand-in script | one check, no client package findings |
| Allowlist | in the app dir via AIO `hocon` | in `/etc/puppetlabs/puppetdb` | read-only root; no AIO agent |
| Config at start | edits files in place | same, on a seeded emptyDir | read-only root |
