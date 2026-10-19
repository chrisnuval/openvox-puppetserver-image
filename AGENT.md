# AGENT.md: Migrate OpenVox Server 8.8.1 on Kubernetes to a hardened UBI 9 image

This document is written for an autonomous coding agent (for example GPT-5.6 Luna) working with a
human operator. It is self-contained: follow it top to bottom. Every phase has **exact commands**,
the **expected result**, and **exit criteria**. Do not skip phases, do not reorder them, and do not
improvise fixes that are not in [Troubleshooting](#troubleshooting).

---

## 0. Rules for the agent (read first, follow always)

1. **Work in order.** Finish a phase's exit criteria before starting the next phase.
2. **Record evidence.** Keep `migration-report.md` (template in [Appendix B](#appendix-b-migration-reportmd-template))
   up to date. Paste the real command output for every exit criterion. Never write "passed" without output.
3. **STOP gates.** When a step says **STOP**, stop, show the operator what you found, and wait for
   an explicit "go". Never pass a STOP gate on your own.
4. **Never, without operator approval in that moment:**
   - change anything in a production namespace (`kubectl apply`, `scale`, `delete`, `patch`, `exec` that writes)
   - delete or recreate a PersistentVolumeClaim (PVC)
   - run anything as root in the cluster
   - push to a registry
5. **The CA is the crown jewel.** The CA private key (`/etc/puppetlabs/puppetserver/ca/ca_key.pem`)
   signs every agent's certificate. Losing it means re-enrolling every node. Back it up before
   touching anything (Phase 7). Never print it, never commit it, never copy it outside the backup location the operator names.
6. **Do not edit these files** (third-party, AGPL-3.0, used unmodified): anything the build downloads
   into `/upstream` (entrypoint scripts). Change behaviour through environment variables or files in `rootfs/` only.
7. **If a command's output differs from "Expected"**, look it up in [Troubleshooting](#troubleshooting).
   If it is not there, **STOP** and report the full output.
8. Prefer the repo's scripts over hand-typed equivalents: they encode lessons already learned.

### Which path?
Find out how the current server is deployed **before Phase 1**:
```bash
helm list -A | grep -i -E 'openvox|puppet'
```
- **A Helm release is listed** (normally the [OpenVox Helm chart](https://github.com/OpenVoxProject/openvox-helm-chart)):
  follow **Path H**, in this order: Phase 0 → **H1** (discovery, read-only; Phase 3 needs the old
  image it finds) → Phases 2, 3, 4, 5 → **H2, H3, H4** (H5 only if triggered) → Phase 10.
  Phases 1, 6, 7, 8 and 9 are **not** used on Path H.
- **Plain manifests** (no Helm release): follow Phases 0–10 in order (Path M).
- **Your own chart / image repos** (a fork or in-house chart, e.g. based on the OpenVox chart but
  different, possibly with PuppetDB/OpenVoxDB and PostgreSQL): start with
  [Path C](#path-c-own-chart-and-image-repos-analysis-first). It analyses your repos against
  [KNOWLEDGE.md](KNOWLEDGE.md) and produces a findings report and change plan, then continues with
  Path H or M for the server. Path H's post-renderer is tied to the public chart 11.0.0 and is
  **not** applied to a fork.

**Read [KNOWLEDGE.md](KNOWLEDGE.md) once before starting.** It lists every problem found in the
reference run (IDs K1–K16), how to recognise it in code you have not seen, and the fix.

---

## 1. Goal and definition of done

Replace the running `ghcr.io/openvoxproject/openvoxserver:8.8.1*` deployment with an image built
from scratch on Red Hat UBI 9, upgraded to OpenVox Server 8.17.0, **keeping the existing CA and
all agent certificates**.

| # | Done when | Evidence |
|---|---|---|
| D1 | Image builds with podman from this repo | build log tail with `Puppet Server has successfully started` from the CDS stage |
| D2 | All functional tests pass, including migration from your exact 8.8.1 image and rollback | `scripts/smoke-test.sh` prints `ALL TESTS PASSED` |
| D3 | No **fixable** vulnerabilities and no CRITICAL ones | `scripts/scan.sh` prints `fixable vulnerabilities: 0`; Aqua report agrees |
| D4 | Kubernetes manifest passes the policy checks, including CKV_K8S_9, CKV_K8S_22, CKV_K8S_40 | scan output: only CKV_K8S_43 may fail before the push, nothing after |
| D5 | Production runs the new image with the **same CA fingerprint** as before | fingerprint before/after in the report |
| D6 | Agents work: existing nodes get catalogs, a new certificate can be signed | canary agent run output; sign + clean of a test cert |
| D7 | Rollback was rehearsed in staging and is documented with exact commands | staging section of the report |

**Important expectation to set with the operator:** "remove all Aqua findings" is achieved as
**zero fixable and zero critical findings**. On UBI 9 there remain roughly 300 medium/low (and
~18 high) findings in packages the server genuinely needs (curl, OpenSSL, Java, Ruby, util-linux,
expat) that Red Hat has marked `affected` / `will_not_fix` with **no fix available**. No rebuild
can remove them; they are normally handled by an Aqua policy that gates on "fix available" or by
recorded exceptions. (UBI 10 brings this to 1 finding, but needs AVX2/x86-64-v3 CPUs on amd64;
see [Appendix D](#appendix-d-ubi-10-option).)

---

## 2. Background (why the design is the way it is)

**What is wrong with the 8.8.1 image**
- Based on Ubuntu 24.04 and the `openvox-agent` all-in-one package, which **vendors its own Ruby
  (3.2), curl, OpenSSL** under `/opt/puppetlabs/puppet`. Those copies only get fixes when OpenVox
  releases a new agent, which is the main source of the Aqua findings. Reference scan (Trivy):
  627 findings, 2 critical, 13 high, **565 fixable**.
- Runs **as root** (no `USER`), the puppet user inside is UID/GID 999.
- Java 17.

**What the Checkov findings mean**
- `CKV_K8S_40`: container must run with `runAsUser` ≥ 10000. New image runs as **UID 64604**.
- `CKV_K8S_22`: root filesystem must be read-only. New image supports `readOnlyRootFilesystem: true`;
  every writable path is a volume, filled from the image at startup.
- `CKV_K8S_9`: a readiness probe is required. `/status/v1/simple` on 8140 answers HTTPS without a
  client certificate, so plain `httpGet` probes work.

**Design decisions (already made and tested; do not revisit)**
| Decision | Reason |
|---|---|
| Install from the release tarball (`artifacts.voxpupuli.org`), not the RPM | The el9 RPM `Requires: openvox-agent` (vendored Ruby/curl/OpenSSL again) and systemd |
| UBI 9 + `ruby:3.3` module stream | UBI 9 default Ruby is 3.0; OpenVox is built against 3.3 |
| `ubi9/ubi-minimal` final stage, `ubi9/ubi` builder | compilers (for the `racc` gem) never reach the final image |
| Remove unused RPMs after install (`REMOVE_UNUSED_RPMS=true`) | python3 (via crypto-policies-scripts), cups-libs/avahi-libs (printing, required by Java), package manager: ~100 findings, never used at runtime. RPM database is kept, so scanners still see everything |
| Upstream entrypoint scripts, unmodified, pinned to commit `d51a221` | every env var of the 8.8.1 image keeps working |
| JRuby gems under `apps/` (read-only), symlinked from the data dir | writable data volume stays ~4 KB |
| Class-data-sharing (CDS) stage boots the server once during the build | faster start; only the `.jsa` file is kept, never certificates |
| No `dumb-init` (not in UBI) | the entrypoint traps SIGTERM itself; tested: clean stop in ~1 s, exit 143 |
| Every download checksummed (`build/checksums.sha256`) | supply-chain integrity |

---

## 3. Environment assumptions and prerequisites

- Build host: Linux **amd64** with **podman ≥ 4** (rootless is fine). No other tools required.
  Docker works too (`ENGINE=docker`), but this document assumes podman.
- Network egress from the build host (or an internal mirror for each):
  | Host | Used for | Required |
  |---|---|---|
  | `registry.access.redhat.com` | UBI base images | yes (or `--build-arg UBI_REGISTRY=<mirror>`) |
  | `cdn-ubi.redhat.com` | UBI RPM repositories | yes |
  | `artifacts.voxpupuli.org` | OpenVox Server / OpenVoxDB tarballs | yes |
  | `github.com`, `codeload.github.com` | entrypoint scripts, core type modules | yes |
  | `rubygems.org` | Ruby gems | yes |
  | `ghcr.io` (or your internal copy) | the **old** image, for the migration test | yes |
  | `docker.io` | optional scanner/linter containers (Trivy, Checkov, Hadolint) | no: `OFFLINE=1` fallback |
  | Trivy DB (`mirror.gcr.io` / `ghcr.io`) | vulnerability database | no: Aqua is the source of truth |
  Behind a proxy: pass `--build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=... --build-arg NO_PROXY=...`.
- Cluster access: `kubectl` with rights to read the current deployment; write rights are used only
  after STOP gates, normally by or with the operator.
- **Path H only:** on the machine that runs Helm, `helm` (3 or 4) and `kubectl` ≥ 1.21 (its built-in
  kustomize is used by the post-renderer), plus access to the chart repository the release was
  installed from. These are usually the operator's deployment tools; if they are missing, **STOP**
  and ask (do not install tools without approval).
- A container registry you can push to (`podman login <registry>` done by the operator).

---

## 4. Repository map

| Path | Purpose | Agent may edit? |
|---|---|---|
| `Containerfile` | 3-stage build: `build` (UBI 9 + compilers) → `app` (ubi-minimal) → `cds` → `final` | only build-arg defaults, with operator approval |
| `build/install-openvox.sh` | builder: download + verify, tarball install, gems, termini, core modules | no (unless Troubleshooting says so) |
| `build/finalize-image.sh` | final stage: `puppet` user (64604), permissions, pristine copies of writable dirs | no |
| `build/sources.sh` | list of every download URL | when changing versions |
| `build/checksums.sha256` | SHA-256 of every download | regenerate with `scripts/update-checksums.sh` only |
| `rootfs/container-entrypoint.d/00-seed-writable-dirs.sh` | fills empty volumes from the image at startup, never overwrites | no |
| `rootfs/usr/local/share/openvox/writable-dirs` | the list of writable paths | no |
| `rootfs/etc/default/puppetserver` | launcher settings (`USER=""`: never switch users) | no |
| `scripts/smoke-test.sh` | functional + migration + rollback tests | no |
| `scripts/scan.sh` | Trivy + Hadolint + Kubernetes policy; podman-only friendly | no |
| `scripts/k8s-policy-check.rb` | Checkov-compatible checks, runs with the image's own Ruby (offline) | no |
| `scripts/cve-summary.py` | summarises a Trivy JSON report | no |
| `scripts/update-checksums.sh` | regenerate checksums after version changes | run only |
| `k8s/openvox-server.yaml` | hardened StatefulSet + Service + NetworkPolicy (template) | **yes**: adapt in Phase 6 |
| `k8s/migration/maintenance-pod.yaml` | one-time root pod (old image) for backup/chown/rollback | **yes**: fill placeholders |
| `.hadolint.yaml` | documented lint exception (unpinned RPMs, on purpose) | no |
| `helm/values-hardened.yaml` | Helm values for the OpenVox chart (Path H) | **yes**: image, digest, resources |
| `helm/post-render/` | post-renderer (kustomize patches + Helm 4 plugin): read-only root, PVC protection, r10k fixes | no |
| `scripts/helm-migration-test.sh` | Helm rehearsal: old setup → hardened upgrade → rollback, with checks | no |
| `scripts/k8s-handover-volumes.sh` | one-time `chown` of a Deployment's PVCs via a root pod running the old image | no |
| `KNOWLEDGE.md` | findings catalogue K1–K16: what to search for, why it breaks, the fix (incl. PuppetDB/OpenVoxDB, PostgreSQL) | no |

---

## 5. Phase 0: Preflight (build host)

```bash
cd <repo>
podman --version                      # Expected: podman version 4.x or 5.x
uname -m                              # Expected: x86_64
podman info --format '{{.Host.Security.Rootless}}'   # true or false; both work
podman pull registry.access.redhat.com/ubi9/ubi-minimal:9.8
podman run --rm registry.access.redhat.com/ubi9/ubi-minimal:9.8 cat /etc/redhat-release
# Expected: Red Hat Enterprise Linux release 9.8 (Plow)
curl -sI https://artifacts.voxpupuli.org/openvox-server/8.17.0/openvox-server-8.17.0.tar.gz | head -1
# Expected: HTTP/2 200 (or HTTP/1.1 200)
```
If `9.8` is not available in your mirror, use the newest `9.x` tag that is and pass
`--build-arg UBI_TAG=<tag>` in every build command below.

**Exit criteria:** all four expected outputs seen; record them in the report.

---

## 6. Phase 1: Discover the current deployment (read-only)

Set variables (ask the operator if unknown):
```bash
NS=<namespace of the current openvox server>
kubectl get deploy,statefulset,svc,ingress,pvc,configmap,secret,networkpolicy -n "$NS" -o wide
```
Identify the workload running the openvoxserver image, then save its full definition:
```bash
KIND=<deployment|statefulset>; NAME=<name>
kubectl get "$KIND" "$NAME" -n "$NS" -o yaml > old-workload.yaml
kubectl get svc -n "$NS" -o yaml > old-services.yaml
POD=$(kubectl get pods -n "$NS" -o name | grep "$NAME" | head -1)
```
Extract the facts below into the report's **Discovery** table. Commands are read-only.

| Fact | How |
|---|---|
| Old image (exact, with digest) | `kubectl get "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].imageID}'` (with sidecars: pick the openvoxserver container's entry) |
| All env vars | `.spec.template.spec.containers[0].env` / `envFrom` in `old-workload.yaml` |
| Every volume and mount path | `.volumes` and `.volumeMounts`; note which are PVC / ConfigMap / Secret / emptyDir |
| PVC names, size, storage class, access mode | `kubectl get pvc -n "$NS" -o wide` |
| Does the storage support ownership changes? | storage class provisioner: NFS/hostPath may **not** (see Phase 7) |
| Service name(s), ports, **selector labels** | `old-services.yaml`; agents connect to this name |
| Server certname | `kubectl exec -n "$NS" "$POD" -- puppet config print certname --section server` |
| CA fingerprint | `kubectl exec -n "$NS" "$POD" -- openssl x509 -noout -fingerprint -sha256 -in /etc/puppetlabs/puppetserver/ca/ca_crt.pem` |
| Number of signed certs | `kubectl exec -n "$NS" "$POD" -- bash -c 'ls /etc/puppetlabs/puppetserver/ca/signed | wc -l'` |
| `CA_HOSTNAME` resolves? | `kubectl exec -n "$NS" "$POD" -- getent hosts "${CA_HOSTNAME:-puppet}"` |
| OpenVoxDB used? version? | `USE_OPENVOXDB`, `OPENVOXDB_SERVER_URLS`; image of the openvoxdb workload |
| r10k used? | env/cronjobs/sidecars running `r10k`; `/etc/puppetlabs/r10k/r10k.yaml` exists? |
| Custom config files on volumes | `kubectl exec -n "$NS" "$POD" -- ls -la /etc/puppetlabs/puppet /etc/puppetlabs/puppetserver/conf.d` |
| Resources, probes, securityContext, nodeSelector, tolerations | `old-workload.yaml` |

**STOP gate 1.** Show the operator the Discovery table. Explicitly flag:
- **No PVC at `/etc/puppetlabs` (or at `/etc/puppetlabs/puppetserver/ca` and `/etc/puppetlabs/puppet/ssl`)**:
  the CA lives only inside the running pod and is lost if the pod restarts. A backup from the
  running pod (Phase 7, variant C) becomes urgent, independent of this migration.
- OpenVoxDB older than 8.17: recommend upgrading it too (separate change).
- Any ConfigMap/Secret mounts (eyaml keys, autosign scripts, r10k SSH keys): they must be mounted
  the same way in the new manifest.

**Exit criteria:** Discovery table complete, operator said "go".

---

## 7. Phase 2: Build

Decide build arguments with the operator (defaults are correct for most cases):

| Arg | Default | Change when |
|---|---|---|
| `UBI_REGISTRY` | `registry.access.redhat.com` | you use an internal mirror |
| `UBI_TAG` | `9.8` | your mirror has a different 9.x |
| `WITH_R10K` | `true` | `false` if Discovery found r10k is not used inside the server (removes git + ssh) |
| `REMOVE_UNUSED_RPMS` | `true` | never, unless Troubleshooting says so |
| `OPENVOXSERVER_VERSION` / `OPENVOXDB_VERSION` / `RUBYGEM_OPENVOX` | `8.17.0` / `8.17.0` / `8.31.0` | not in this migration |

```bash
IMAGE=openvox-server-ubi:8.17.0
podman build --format docker -t "$IMAGE" . 2>&1 | tee build.log
```
- `--format docker` keeps the `HEALTHCHECK` (OCI format silently drops it).
- Takes 5–15 minutes. The `cds` stage boots the server and then waits up to 90 s; that wait is normal.

Expected near the end of `build.log`:
```
... INFO  [p.s.m.master-service] Puppet Server has successfully started and is now ready to handle requests
... COMMIT openvox-server-ubi:8.17.0
```
Check basics:
```bash
podman run --rm --entrypoint bash "$IMAGE" -c 'id; ruby -v; java -version 2>&1 | head -1; puppet --version'
# Expected:
# uid=64604(puppet) gid=0(root) groups=0(root)
# ruby 3.3.x ...
# openjdk version "21.x" ...
# 8.31.0
```

**Exit criteria:** build succeeded, the four expected lines match. Record image ID:
`podman image inspect "$IMAGE" --format '{{.Id}}'`.

---

## 8. Phase 3: Functional tests

Use the **exact old image** from Discovery (by digest if possible) so the migration test uses the
same files your cluster has:
```bash
OLD_IMAGE=<old image from Discovery (Phase 1, or H1 on Path H), e.g. ghcr.io/openvoxproject/openvoxserver@sha256:...>
scripts/smoke-test.sh "$IMAGE" "$OLD_IMAGE" 2>&1 | tee smoke-test.log
```
Takes 5–10 minutes. Expected output (fingerprints differ):
```
PASS  no keys or certificates baked into the image
PASS  runs as UID 64604 (>= 10000)
PASS  server starts (plain run)
PASS  catalog compiles (incl. vendored Cron type)
PASS  puppetserver ca list
PASS  eyaml encrypt/decrypt
PASS  r10k + git                                  (only with WITH_R10K=true)
PASS  SIGTERM shutdown in 1s (exit 143)
PASS  server starts with read-only root
PASS  root filesystem is read-only
PASS  catalog compiles with read-only root
== migration from <OLD_IMAGE>
PASS  old image starts
PASS  new image starts on the old volume
PASS  CA kept (sha256 Fingerprint=...)
PASS  catalog compiles with migrated certificates
PASS  new image signs certificates with the migrated CA
PASS  rollback: old image starts on the migrated volume
PASS  rollback: CA unchanged
PASS  rollback: certificate signed by the new image is still there
PASS  rollback: old image can still sign

ALL TESTS PASSED
```
What the migration tests prove: they run the same ownership steps as the cluster cutover
(`chown -R 64604:64604` before the new image, `chown -R 999:999` for rollback) on a volume the
old image created.

> **Known trap, already handled:** Kubernetes `fsGroup` alone is **not** enough when migrating.
> The CA rewrites files (serial, inventory) and copies the old file's *owner* onto the new file. A
> non-root UID 64604 cannot set owner 999, so certificate **signing fails with HTTP 500
> "Operation not permitted"** while everything else looks healthy. The one-time `chown` in
> Phase 7 prevents this. Never skip it.

**Exit criteria:** `ALL TESTS PASSED`; attach `smoke-test.log` to the report.

---

## 9. Phase 4: Security scans

```bash
scripts/scan.sh "$IMAGE" 2>&1 | tee scan.log
# Without docker.io access:  OFFLINE=1 scripts/scan.sh "$IMAGE"
```
`scan.sh` uses local tools if installed, otherwise pinned containers (`aquasec/trivy:0.76.0`,
`bridgecrew/checkov:3.3.20`, `hadolint/hadolint:v2.15.1`). With `OFFLINE=1` it skips Trivy and
Hadolint and runs `scripts/k8s-policy-check.rb` inside the image under test (same check IDs as
Checkov, verified to flag the identical 19 checks on a bare 8.8.1-style manifest).

Expected (numbers drift as CVEs are published; what matters is fixable = 0, critical = 0):
```
openvox-server-ubi:8.17.0: CRITICAL 0, HIGH ~18, MEDIUM ~180, LOW ~130 ...  (fix available 0)
  fixable vulnerabilities: 0
== Hadolint: Containerfile
  clean
== Kubernetes policy: k8s/
  Passed checks: 88-89, Failed checks: 1       (Checkov; the count depends on the build)  or  Passed checks: 21, Failed checks: 1 (offline)
  Check: CKV_K8S_43: "Image should use digest"  (fixed in Phase 6)
SCAN OK
```
Then the operator scans the image with **Aqua** (the source of truth). Compare with `scan.log`:
- Fixable findings in Aqua but not in Trivy: rebuild first (`podman build --no-cache ...`, newer
  RPMs), rescan. If still present, **STOP** and report package, CVE, installed and fixed version.
- `CVE-2022-41404 (org.ini4j)`: inside openvox-server's own jar, no fix exists, also present upstream.
  Record as an accepted exception.
- Unfixed (`affected` / `will_not_fix`) RHEL 9 findings: record as accepted; they disappear only
  with Red Hat fixes (rebuild regularly) or UBI 10.

**Exit criteria:** fixable = 0, critical = 0 in Trivy **and** Aqua; Hadolint clean; policy shows
only CKV_K8S_43. Record the Aqua summary in the report.

---

## 10. Phase 5: Push

**STOP gate 2:** operator approves pushing to `<registry>/<path>`.
```bash
REG=<registry>/<path>/openvox-server-ubi
podman tag "$IMAGE" "$REG:8.17.0"
podman push --digestfile digest.txt "$REG:8.17.0"
DIGEST=$(cat digest.txt); echo "$REG@$DIGEST"
```
**Exit criteria:** pushed; `$REG@$DIGEST` recorded. Use this exact reference everywhere below.

---

## 11. Phase 6: Prepare the Kubernetes manifest

Start from `k8s/openvox-server.yaml` and adapt it to the Discovery facts. Keep every security
setting; change only what is listed here.

1. `metadata.namespace` → `$NS` (all three objects).
2. `image:` → `$REG@$DIGEST` (fixes CKV_K8S_43).
3. **Volumes, the critical part.** Do **not** use `volumeClaimTemplates` for an existing server:
   they create new, empty PVCs and therefore a **new CA**. Delete the `volumeClaimTemplates`
   block and reference the existing PVC(s) under `spec.template.spec.volumes`:
   - **A. Old server had one PVC at `/etc/puppetlabs`:**
     ```yaml
     - name: puppetlabs-etc
       persistentVolumeClaim:
         claimName: <existing PVC>
     ```
     (mount stays `mountPath: /etc/puppetlabs`).
   - **B. Old server had several PVCs on sub-paths** (e.g. `/etc/puppetlabs/puppet/ssl`,
     `/etc/puppetlabs/puppetserver/ca`, `/etc/puppetlabs/code`): keep `puppetlabs-etc` as
     `emptyDir: {}` (config is regenerated from env at every start) and add each PVC with the
     **same mountPath as before**, nested below it. Startup fills only missing files, so PVC
     contents are never overwritten.
   - **C. Old server had no PVC for the CA:** create a new PVC (operator decides size/class; 2Gi is
     plenty), and restore the backup into it in Phase 7 (variant C).
   - Keep the `data`, `puppet-cache`, `logs`, `run`, `run-openvox` and `tmp` emptyDirs. If the old
     server had a PVC on `/opt/puppetlabs/server/data/puppetserver` (reports, filebucket), use it instead of the `data` emptyDir.
4. ConfigMap/Secret mounts from Discovery: copy them unchanged (same mountPath, same items).
5. Env: copy **every** env var from the old workload. Then:
   - set `CERTNAME` to the server certname from Discovery (pod names change; the certname must not).
   - keep `CA_HOSTNAME` as before; it must resolve from inside the pod.
   - if `OPENVOXSERVER_JAVA_ARGS` was overridden, append
     `-XX:SharedArchiveFile=/opt/puppetlabs/server/apps/puppetserver/puppetserver.jsa`.
   - remove nothing security-relevant from the template (`readOnlyRootFilesystem`, `runAsUser`, ...).
6. **Service:** agents use the existing Service name. Either keep the old Service and make its
   selector match the new pod labels (`app.kubernetes.io/name: openvox-server`), or add the old
   selector labels to the new pod template labels. Do not create a second Service with the same name.
7. `resources`: at least what the old workload had; keep `limits.memory` ≥ heap + 1 GiB.
8. `NetworkPolicy`: narrow `from:` to the agent networks if the operator knows them.
9. If the old workload was a Deployment named the same as the new StatefulSet, choose a different
   name for the StatefulSet or delete the Deployment at cutover (operator decides).

Fill `k8s/migration/maintenance-pod.yaml`: `<NAMESPACE>`, `<OLD_IMAGE_EXACTLY_AS_DEPLOYED>`, and one
`volumeMounts`/`volumes` pair **per PVC, at the old mount paths**.

Validate:
```bash
scripts/scan.sh "$IMAGE"          # policy section must show 0 failed checks now (digest is set)
kubectl apply --dry-run=server -f k8s/openvox-server.yaml -n "$NS"
kubectl apply --dry-run=server -f k8s/migration/maintenance-pod.yaml
```
**Exit criteria:** policy shows `Failed checks: 0` (Checkov or offline checker), both dry-runs succeed. Show the operator the diff
between `old-workload.yaml` and the new manifest.

---

## 12. Phase 7: Staging rehearsal (strongly recommended)

Rehearse the whole cutover and rollback on a **copy** of production data in a separate
namespace. The copy contains the real CA private key: treat the staging namespace as production-sensitive and delete it afterwards.

**STOP gate 3:** operator approves creating namespace `<NS>-staging`, and a root maintenance pod in it.

1. **Backup** production (read-only `tar` from the running old pod; it runs as root and has tar):
   ```bash
   TS=$(date +%Y%m%d-%H%M%S)
   kubectl exec -n "$NS" "$POD" -- tar -czf - -C /etc/puppetlabs . > "backup-etc-puppetlabs-$TS.tgz"
   sha256sum "backup-etc-puppetlabs-$TS.tgz" | tee "backup-etc-puppetlabs-$TS.tgz.sha256"
   tar -tzf "backup-etc-puppetlabs-$TS.tgz" | grep -E 'puppetserver/ca/ca_(crt|key)\.pem$'
   # Expected: ./puppetserver/ca/ca_crt.pem and ./puppetserver/ca/ca_key.pem
   ```
   Repeat for any other PVC path (e.g. the data dir). Store backups where the operator says (never in git).
2. Create the staging namespace, a PVC like production's, and the maintenance pod pointed at it.
3. Restore into the staging PVC and hand it to the new user:
   ```bash
   kubectl exec -i -n "$NS-staging" openvox-maint -- tar -xzf - -C /etc/puppetlabs < "backup-etc-puppetlabs-$TS.tgz"
   kubectl exec -n "$NS-staging" openvox-maint -- chown -R 64604:64604 /etc/puppetlabs
   kubectl delete pod -n "$NS-staging" openvox-maint
   ```
4. Apply the new manifest with namespace `$NS-staging` and the staging PVC name.
5. **Verify** (all must pass):
   ```bash
   kubectl rollout status statefulset/openvox-server -n "$NS-staging" --timeout=10m
   P=openvox-server-0
   kubectl exec -n "$NS-staging" $P -- openssl x509 -noout -fingerprint -sha256 -in /etc/puppetlabs/puppetserver/ca/ca_crt.pem
   #   Expected: identical to the production CA fingerprint from Discovery
   kubectl exec -n "$NS-staging" $P -- bash -c 'ls /etc/puppetlabs/puppetserver/ca/signed | wc -l'
   #   Expected: same count as production
   kubectl exec -n "$NS-staging" $P -- puppetserver ca generate --certname staging-signing-test.invalid
   #   Expected: "Successfully saved certificate ..." (proves the CA is writable; see Phase 3 trap)
   kubectl exec -n "$NS-staging" $P -- puppetserver ca clean --certname staging-signing-test.invalid
   kubectl exec -n "$NS-staging" $P -- touch /usr/x
   #   Expected: "Read-only file system"
   kubectl logs -n "$NS-staging" $P | grep -E "successfully started|ERROR" | head
   ```
   If a test agent can reach staging: `puppet agent -t --noop --server <staging service DNS>` on
   one node; expected: catalog applied in noop, no certificate errors.
6. **Rehearse rollback** in staging: scale the StatefulSet to 0, recreate the maintenance pod,
   `chown -R 999:999 /etc/puppetlabs`, delete it, start the old image on the PVC (old manifest
   with staging namespace), verify the same CA fingerprint and `ca list` works.
7. Delete the staging namespace (and its PVCs) after the operator confirms.

**Exit criteria:** every verify line matches; rollback rehearsal worked; times recorded (they
predict the production maintenance window).

---

## 13. Phase 8: Production cutover

**STOP gate 4:** operator approves the maintenance window. Agents retry failed runs, so a short
outage (typically 5–15 minutes) only delays runs; nothing is lost.

```bash
# 1. Record the "before" state
kubectl get "$KIND" "$NAME" -n "$NS" -o yaml > old-workload-at-cutover.yaml
# 2. Stop the old server (the PVC is ReadWriteOnce: only one pod may mount it)
kubectl scale "$KIND" "$NAME" -n "$NS" --replicas=0
kubectl wait --for=delete pod -l <old pod selector> -n "$NS" --timeout=5m
# 3. Final backup + ownership change, via the maintenance pod (runs the OLD image as root)
kubectl apply -f k8s/migration/maintenance-pod.yaml
kubectl wait --for=condition=Ready pod/openvox-maint -n "$NS" --timeout=5m
TS=$(date +%Y%m%d-%H%M%S)
kubectl exec -n "$NS" openvox-maint -- tar -czf - -C /etc/puppetlabs . > "backup-cutover-$TS.tgz"
sha256sum "backup-cutover-$TS.tgz" | tee "backup-cutover-$TS.tgz.sha256"
tar -tzf "backup-cutover-$TS.tgz" | grep -c 'puppetserver/ca/ca_key.pem'      # Expected: 1
kubectl exec -n "$NS" openvox-maint -- chown -R 64604:64604 <every PVC mount path>
kubectl delete pod openvox-maint -n "$NS" --wait=true
# 4. Start the new server
kubectl apply -f k8s/openvox-server.yaml
kubectl rollout status statefulset/openvox-server -n "$NS" --timeout=10m
```
If the storage does **not** support `chown` (some NFS exports with root squash): the `chown` fails.
**STOP**, do not continue; the operator must run the chown on the NFS server side, or move the
data to a PVC on a storage class that supports ownership.

**Verify** (same as staging, against production):
- CA fingerprint identical to Discovery; signed-cert count identical.
- `puppetserver ca generate --certname cutover-signing-test.invalid` succeeds, then `ca clean` it.
- 1–3 canary agents: `puppet agent -t`. Expected: catalog applied, no SSL errors.
- `kubectl get events -n "$NS" --sort-by=.lastTimestamp | tail` shows no probe failures after start.
- Delete the old Deployment/StatefulSet object only after 24 h of healthy operation (operator decides).

**Rollback triggers:** pod not Ready after 10 minutes, CA fingerprint differs, signing fails,
canary agents fail with certificate errors.

---

## 14. Phase 9: Rollback (only if triggered)

**STOP gate 5:** operator confirms rollback.
```bash
kubectl scale statefulset/openvox-server -n "$NS" --replicas=0
kubectl wait --for=delete pod/openvox-server-0 -n "$NS" --timeout=5m
kubectl apply -f k8s/migration/maintenance-pod.yaml
kubectl wait --for=condition=Ready pod/openvox-maint -n "$NS" --timeout=5m
kubectl exec -n "$NS" openvox-maint -- chown -R 999:999 <every PVC mount path>
kubectl delete pod openvox-maint -n "$NS" --wait=true
kubectl scale "$KIND" "$NAME" -n "$NS" --replicas=1       # the old workload object, unchanged
```
Certificates signed by the new server in the meantime remain valid (tested). If the PVC content
itself is damaged, restore from `backup-cutover-$TS.tgz` with the maintenance pod
(`tar -xzf - -C /etc/puppetlabs`) before scaling the old workload up.

---

## Path H: deployed with the OpenVox Helm chart

Use this instead of Phases 1, 6, 7, 8 and 9 when the server runs from a Helm release. Phases 0, 2,
3, 4, 5 and 10 apply unchanged. Files: `helm/values-hardened.yaml`, `helm/post-render/`,
`scripts/helm-migration-test.sh` (details in `helm/README.md`).

### H0. What the chart does, and what this repo changes (read once)

| Chart behaviour (chart 11.0.0) | Consequence | Handled by |
|---|---|---|
| **`global.runAsNonRoot: true` turns every PVC into a `pre-install` hook** (in root mode they are normal release resources) | **`helm upgrade` DELETES the existing PVCs, including the CA**: hooks aren't release resources, so Helm treats them as removed. Reproduced in the rehearsal | post-renderer removes the hook annotation and adds `helm.sh/resource-policy: keep`; H4 also annotates the live PVCs `keep` first (two independent safeguards) |
| Default root mode: init container `perms-and-dirs` runs as **root** and `chown`s volumes to 64604 at every start, then the old image's entrypoint (root) gives the CA/SSL files back to its own puppet user **999:999** | **CKV_K8S_40** fails; files end up owned by 999, so signing fails after the upgrade unless they are handed over | `global.runAsNonRoot: true` in `values-hardened.yaml`; one-time handover `scripts/k8s-handover-volumes.sh` (H4) |
| No setting for `readOnlyRootFilesystem` on the server | **CKV_K8S_22** fails | post-renderer: read-only root + scratch emptyDirs |
| Non-root mode runs `exec puppetserver foreground`, skipping the image entrypoint | env-var config (`DNS_ALT_NAMES`, autosign, ...) and volume seeding never run | post-renderer removes `command`/`args` |
| Non-root mode adds a root **pre-install Job** to copy config into volumes | fails CKV_K8S_22/40; not needed (image seeds itself) | post-renderer deletes it |
| **Every PVC is a `pre-install` hook**: created on first install only, never on upgrade | upgrading root → non-root references a `*-puppetserver-claim` PVC that doesn't exist; the pod stays **Pending** forever | post-renderer uses an emptyDir for `/etc/puppetlabs/puppetserver` (regenerated every start, as in root mode; the CA keeps its own PVC) |
| `RollingUpdate` (default surge) with ReadWriteOnce PVCs | deadlock on multi-node clusters; briefly two CA servers | `maxSurge: 0, maxUnavailable: 1` in `values-hardened.yaml` (switching to `Recreate` is rejected by server-side apply) |
| Chart sets `replicas` only for multi-master | after the handover (scaled to 0) `helm upgrade` would leave the server at 0 replicas | post-renderer pins `replicas: 1` |
| r10k sidecar image writes `/etc/passwd`, `~/.r10k_*`, `/etc/puppetlabs/r10k` at startup | with a read-only root **every r10k deploy fails** | post-renderer: passwd init container (non-root) + emptyDirs |
| PuppetDB Deployment (openvoxdb image) and Bitnami PostgreSQL subchart | still fail CKV_K8S_22/40 | **not covered**: separate follow-up, report as open item |

Post-renderer: set `POST` once per shell, from the repo root, and check it. **Never run a
`helm upgrade` in H4 with `$POST` empty**: without the post-renderer the chart deletes the PVCs.
```bash
if helm version --short | grep -q '^v3'; then
  POST="--post-renderer $PWD/helm/post-render/post-render.sh"
else                                                  # Helm 4: post-renderers are plugins
  helm plugin list | grep -q '^openvox-hardening' || helm plugin install ./helm/post-render
  POST="--post-renderer openvox-hardening"
fi
echo "POST=$POST"          # Expected: non-empty
```
After editing anything under `helm/post-render/` with Helm 4, reinstall the plugin
(`helm plugin uninstall openvox-hardening && helm plugin install ./helm/post-render`).

### H1. Discover the release (read-only)
```bash
helm list -A | grep -i -E 'openvox|puppet'          # note NAME, NAMESPACE, CHART (name-version), REVISION
REL=<name>; NS=<namespace>; CHART_REF=<repo/chart or path>; CHART_VER=<version from CHART column>
helm get values "$REL" -n "$NS" > current-values.yaml          # the operator's values (no defaults)
helm get manifest "$REL" -n "$NS" > old-manifest.yaml
helm history "$REL" -n "$NS"
helm search repo "$CHART_REF" --versions | grep -F "$CHART_VER"   # the chart version must be fetchable; if not: STOP, ask for the repo (helm repo add)
POD=$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=puppetserver -o name | head -1)
C=$(kubectl get -n "$NS" "$POD" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep -v '^r10k-' | head -1)   # server container
kubectl get -n "$NS" "$POD" -o jsonpath="{.status.containerStatuses[?(@.name==\"$C\")].imageID}"   # = OLD_IMAGE for Phase 3
kubectl exec -n "$NS" "$POD" -c "$C" -- openssl x509 -noout -fingerprint -sha256 -in /etc/puppetlabs/puppetserver/ca/ca_crt.pem
kubectl exec -n "$NS" "$POD" -c "$C" -- bash -c 'ls /etc/puppetlabs/puppetserver/ca/signed | wc -l'
kubectl exec -n "$NS" "$POD" -c "$C" -- stat -c '%u:%g %n' /etc/puppetlabs/puppetserver/ca/ca_key.pem /etc/puppetlabs/puppet/ssl/certs/ca.pem
#   Typical with the 8.8.1 image: 999:999 (its entrypoint re-owns them); either way H4 hands them over
```
(`helm search repo` applies to a classic repo; for an OCI or local chart, `CHART_REF` is the
`oci://...` URL or path and this line can be skipped.)
Record in the report: old image digest, chart version, `current-values.yaml` (redact secrets), CA fingerprint, signed
count, owners, and whether these are set: `puppetserver.puppeturl` (r10k), `hiera.*`/eyaml,
`puppetserver.compilers.enabled`, `puppetserver.persistence.data.enabled`, `puppetdb.enabled`,
`postgresql.enabled`, `singleCA.enabled`, `puppetserver.masters.multiMasters.enabled`.

**STOP gate H1.** Show the operator the facts. Additionally flag:
- Chart version is not `11.0.0`: the post-renderer was built and tested against 11.0.0. Continue to H2,
  which detects incompatibilities; do **not** upgrade the chart version in the same change.
- `compilers.enabled`, `multiMasters.enabled` or `singleCA.enabled` is true: not covered by the
  post-renderer or the tests. Stop here and report.

### H2. Prepare values and render offline
Edit `helm/values-hardened.yaml`: set `puppetserver.image` to your registry path and
`puppetserver.tag` to `8.17.0@sha256:<digest>` from Phase 5. Then render exactly what the upgrade
will apply, with the **same chart version** as today:
```bash
helm template "$REL" "$CHART_REF" --version "$CHART_VER" -n "$NS" \
  -f current-values.yaml -f helm/values-hardened.yaml | helm/post-render/post-render.sh > new-manifest.yaml
# Expected: exit 0. A kustomize error such as "remove operation does not apply" means this chart
# version differs from 11.0.0 -> STOP and report the full error.
grep -c 'kind: Job' new-manifest.yaml              # the preinstall Job must be gone (0 unless you have other Jobs)
podman run --rm -v "$PWD:/w:ro,Z" docker.io/bridgecrew/checkov:3.3.20 -f /w/new-manifest.yaml \
  --framework kubernetes --check CKV_K8S_9,CKV_K8S_22,CKV_K8S_40 --compact
# offline alternative: podman run --rm -v "$PWD:/w:ro,Z" --entrypoint ruby "$IMAGE" /w/scripts/k8s-policy-check.rb /w/new-manifest.yaml
diff <(grep -v '^#' old-manifest.yaml) new-manifest.yaml > manifest.diff; wc -l manifest.diff
```
Expected Checkov: no CKV_K8S_9/22/40 failures for the `*-puppetserver-master` Deployment. Failures on
`*-puppetdb` and `*-postgresql` are expected (not covered, see H0). Show `manifest.diff` to the operator.

### H3. Rehearse in a throwaway namespace (strongly recommended)
**STOP gate H3:** operator approves a rehearsal namespace (never production) and confirms any
Secrets/ConfigMaps your values reference (eyaml keys, r10k deploy key) exist there.
```bash
NS=openvox-rehearsal CHART="$CHART_REF" CLEANUP=1 \
OLD_ARGS="--version $CHART_VER -f current-values.yaml" \
NEW_ARGS="--version $CHART_VER -f current-values.yaml -f helm/values-hardened.yaml" \
scripts/helm-migration-test.sh 2>&1 | tee helm-rehearsal.log
```
It installs the old setup (a fresh CA, so it tests mechanics, not your real CA), upgrades with the
hardened setup, verifies, rolls back with `helm rollback`, verifies again. Expected:
```
PASS  old chart setup installed
PASS  PVCs annotated helm.sh/resource-policy=keep
PASS  volumes handed over to 64604:64604
PASS  helm upgrade to hardened setup
PASS  PVCs kept (same UIDs, not recreated)
PASS  server runs as UID 64604
PASS  root filesystem is read-only
PASS  CA unchanged after upgrade
PASS  CA can sign after upgrade
PASS  r10k deploy works (read-only root)          (only if puppeturl is set)
PASS  helm rollback
PASS  CA unchanged after rollback
PASS  CA can sign after rollback
ALL HELM MIGRATION TESTS PASSED
```
If r10k is configured, also check a deploy works after the upgrade (before cleanup, or rerun with
`CLEANUP=0`): `kubectl exec -n openvox-rehearsal <pod> -c r10k-code -- /etc/puppetlabs/puppet/r10k_code_cronjob.sh; echo $?` → `0`.

### H4. Production upgrade
**STOP gate H4:** operator approves the maintenance window **and** running a short-lived root pod
(old image) in the namespace for the ownership handover. The server is down from step 2 until the
new pod is Ready (the rehearsal timing predicts it; agents just retry).
```bash
# 1. Backup CA and SSL from the running pod (old image runs as root and has tar)
TS=$(date +%Y%m%d-%H%M%S)
kubectl exec -n "$NS" "$POD" -c "$C" -- tar -czf - -C /etc/puppetlabs puppetserver/ca puppet/ssl > "backup-$REL-$TS.tgz"
sha256sum "backup-$REL-$TS.tgz" | tee "backup-$REL-$TS.tgz.sha256"
tar -tzf "backup-$REL-$TS.tgz" | grep -c 'puppetserver/ca/ca_key.pem'      # Expected: 1
# 1b. NEVER SKIP: protect every PVC of the release. Helm does not delete a live object annotated
#     keep; this is the second safeguard against the chart deleting the CA volume (H0, first row).
kubectl annotate pvc -n "$NS" -l "app.kubernetes.io/instance=$REL" helm.sh/resource-policy=keep --overwrite
kubectl get pvc -n "$NS" -l "app.kubernetes.io/instance=$REL" \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,KEEP:.metadata.annotations.helm\.sh/resource-policy | tee pvc-before.txt
#     Expected: every chart PVC listed (ca, code, puppet, ...) with KEEP = keep. Record the UIDs.
# 2. Hand the volumes over to UID 64604: scales the server to 0, chowns its PVCs from a root pod
#    running the OLD image, deletes that pod. Required: without it CA signing fails (HTTP 500).
DEPLOY=$(kubectl get deploy -n "$NS" -l app.kubernetes.io/component=puppetserver -o name | cut -d/ -f2)
OLD_IMAGE=$(kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$C\")].image}")
scripts/k8s-handover-volumes.sh "$NS" "$DEPLOY" "$OLD_IMAGE" 64604:64604
#   Expected last lines: "64604:64604 /etc/puppetlabs/..." for every volume, then "done: ..."
#   If chown fails (e.g. NFS with root squash): STOP. Restore the old server with
#   `kubectl scale deploy "$DEPLOY" -n "$NS" --replicas=1` (the chart doesn't set replicas, so
#   helm commands won't) and report; the storage needs an owner change on the server side.
# 3. Upgrade (same chart version, current values + hardened values + post-renderer)
[ -n "$POST" ] || { echo "POST is empty: set it (H0) before upgrading"; exit 1; }
helm upgrade "$REL" "$CHART_REF" --version "$CHART_VER" -n "$NS" \
  -f current-values.yaml -f helm/values-hardened.yaml $POST --wait --timeout 15m
```
Verify first that **no PVC was replaced**: `kubectl get pvc -n "$NS" -l "app.kubernetes.io/instance=$REL"
-o custom-columns=NAME:.metadata.name,UID:.metadata.uid` must show the same UIDs as `pvc-before.txt`.
If any UID differs or a PVC is missing: **STOP immediately** (H5, then restore from the H4 backup).
Then verify exactly as in Phase 8 (CA fingerprint and signed count identical to H1, sign + clean a
`cutover-signing-test.invalid` certificate, canary agents, events), plus the r10k check from H3.

### H5. Rollback (only if triggered)
**STOP gate H5:** operator confirms.
```bash
helm history "$REL" -n "$NS"                                   # revision before the upgrade
helm rollback "$REL" <previous revision> -n "$NS" --wait --timeout 15m
```
The old root-mode init container re-applies ownership on start, so no manual `chown` is needed
(tested: CA unchanged, signing works). Restore from the H4 backup only if the CA files themselves
are damaged (maintenance pod, Phase 9).

---

## Path C: own chart and image repos (analysis first)

For repositories the reference run never saw: a company chart derived from the OpenVox (or older
Vox Pupuli) chart, and image repos for the server and PuppetDB/OpenVoxDB. The agent knows where
these repos are from its own configuration. **Nothing from them leaves the company environment**:
do not paste their content into external tools, issues or web searches; use the offline checker
(`OFFLINE=1`, `scripts/k8s-policy-check.rb`) if container registries for scanners are not approved.

Rules on top of section 0: Path C is **read-only** until STOP gate C4. Work on a branch in each repo.

### C1. Inventory (read-only)
For each repo, record in the report:
- **Chart:** chart name/version, `Chart.yaml` dependencies (PostgreSQL subchart?), workloads
  (`grep -rn '^kind:' templates/`), the values files used per environment (ask the operator which
  one production uses), image references and tags for every container incl. init/sidecars.
- **Server image repo:** base image, how OpenVox is installed (AIO `openvox-agent`/`puppet-agent`
  package = K11 source of CVEs), `USER`, entrypoint, version.
- **DB image repo / image:** which image actually runs (`ghcr.io/voxpupuli/puppetdb:8.8.1-*` is the
  Perforce-based PuppetDB 8.8.1; there is no `openvoxdb:8.8.1`, see K14), env names (`PUPPETDB_*`
  vs `OPENVOXDB_*`, K16), `USER` in `/etc/default/puppetdb`.
- **Live state** (read-only, like H1/Phase 1): for each workload the running image digest, file
  owners on each PVC (`stat -c '%u:%g %n'` on the CA key, SSL dir, PuppetDB `certs/`), PVC names
  and UIDs, CA fingerprint, PuppetDB certname and database name (`kubectl exec ... -- env | grep -E 'PUPPETDB|OPENVOXDB|CERTNAME'`, never print passwords).

### C2. Search for known findings
Run the search list in [KNOWLEDGE.md section 1](KNOWLEDGE.md#1-quick-search-list) on the chart repo.
For each hit, record file:line and the K-ID. Then render the chart **twice** with production values:
```bash
helm dependency build <chart dir>       # only if Chart.yaml has dependencies (e.g. postgresql); uses the configured chart repos
helm template "$REL" <chart dir> -n "$NS" -f <prod values> > render-old.yaml        # as deployed today
podman run --rm -v "$PWD:/w:ro,Z" --entrypoint ruby "$IMAGE" /w/scripts/k8s-policy-check.rb /w/render-old.yaml > policy-old.txt
grep -c FAIL policy-old.txt
```
(`$IMAGE` is the server image from Phase 2; any image with Ruby works. Or the Checkov container.)
Compare `render-old.yaml` with `helm get manifest "$REL" -n "$NS"`: if they differ, the repo is not
what runs; **STOP** and ask which commit/values are deployed.

### C3. Findings report
Write a table per workload (server, r10k/other sidecars, DB, PostgreSQL, helper init containers):

| Workload / container | Failed checks | K-IDs | Location (file:line) | Proposed fix | Data risk |
|---|---|---|---|---|---|

"Data risk" is **yes** for anything touching PVCs, ownership, PVC annotations/hooks (K2, K5),
database name/user, certnames (K16): those need the handover/backup steps and a rehearsal.
Also list: CVE sources per image (K11), and anything you could not classify (do not guess a fix).

### C4. Change plan (STOP gate C4)
Propose the changes in this order (each a separate commit/PR), show the plan, wait for "go":
1. **Server image:** build this repo's image (Phases 2–5) or port its approach into the company
   server image repo (tarball install on UBI, UID 64604, seed dirs, `USER=""`).
2. **Chart, server workload:** apply K1, K3, K4, K5, K6, K7, K8, K9, K10, K12 in the templates
   (values switches with secure defaults). Use `helm/post-render/` and `k8s/openvox-server.yaml` as
   the reference for exact securityContext, volumes and probes. PVC templates: no hooks,
   `helm.sh/resource-policy: keep`.
3. **DB image:** OpenVoxDB 8.17.0 built the same way as the server (K11, K16): UBI 9 minimal, Java 21,
   tarball from `artifacts.voxpupuli.org/openvoxdb/8.17.0/`, UID 64604, `USER=""` in
   `/etc/default/puppetdb`, seed copy of `/etc/puppetlabs/puppetdb`, writable allowlist location
   (K3), entrypoint scripts from the upstream openvoxdb container repo, unmodified. This was **not**
   built in the reference run: give it its own smoke test (start against PostgreSQL + the server,
   cert request, `/status/v1/services/puppetdb-status` = running, a report/fact submission from the
   server, read-only root), its own scan (0 fixable), and a migration test from the exact running
   PuppetDB image on a copy of its data PVC **and** a `pg_dump` of its database.
4. **Chart, DB workload:** K1–K4, K12 for the DB Deployment and its init containers; env renamed
   per K16 with the **old values set explicitly** (database name, user, `CERTNAME`).
5. **PostgreSQL:** K15 (or confirm it is external/out of scope with the operator).

### C5. Implement, test, rehearse
- Per change: `helm lint`, render, policy check (target: only CKV_K8S_43 until digests are set,
  then none), `diff` of renders before/after, shown to the operator.
- Before the rehearsal, render old and new and compare **PVC annotations** (K5):
  ```bash
  for f in render-old.yaml render-new.yaml; do echo "== $f"; ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0])).compact.select{|d| d["kind"]=="PersistentVolumeClaim"}.each{|d| puts "#{d["metadata"]["name"]} #{(d["metadata"]["annotations"]||{}).inspect}"}' "$f"; done
  ```
  Expected: same PVC names in both, no `helm.sh/hook`, `keep` in the new render. (On the public
  chart, `--set global.runAsNonRoot=true` shows `"helm.sh/hook"=>"pre-install"` on the CA PVC:
  exactly the K5 deletion case.)
- Rehearse in a throwaway namespace with `scripts/helm-migration-test.sh`, after adapting its pod
  and PVC selectors to the chart's labels (KNOWLEDGE.md section 3), and extend it with the DB
  checks from step 3. Expected: the same PASS lines as in H3, plus the DB checks.
- Production follows H4/H5 (backup, `keep` annotation, handover of **every** PVC incl. the DB's,
  `pg_dump`, upgrade, verify PVC UIDs, CA fingerprint, signing, DB status, agent runs).
  Without the post-renderer, `$POST` is not used; the hardening is in the templates.

**Exit criteria:** findings report and change plan approved (C4); every change rendered, policy
checked and rehearsed with all PASS lines; DB and PostgreSQL items either done or recorded as open.

---

## 15. Phase 10: After the migration

- Rebuild weekly (or on Red Hat security errata) with `podman build --no-cache`, run
  `scripts/smoke-test.sh "$IMAGE"` and `scripts/scan.sh "$IMAGE"`, push, update the digest.
- Version upgrades (e.g. 8.18.0): change `OPENVOXSERVER_VERSION`, `OPENVOXDB_VERSION`,
  `RUBYGEM_OPENVOX` in `Containerfile`, run `scripts/update-checksums.sh`, rebuild, run all tests.
  OpenVox 9.x is a major upgrade: separate project (see Appendix D notes).
- Keep `backup-cutover-*.tgz` in the operator's secret store; schedule regular CA backups.

---

## Troubleshooting

Every entry below happened during the reference run and is already fixed in this repo. If you
see it again, the fix tells you what changed.

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (35) TLS connect error` during build | transient network | downloads use `--retry 5 --retry-all-errors`; just rebuild. Persistent: proxy args, mirror |
| `No checksum for <file>` | a version arg changed without new checksums | `scripts/update-checksums.sh` (needs network), commit the new `build/checksums.sha256` |
| `sha256sum: WARNING: ... did NOT match` | download changed or was tampered with | **STOP**. Do not regenerate checksums without the operator |
| `Fatal glibc error: CPU does not support x86-64-v3` | UBI **10** on a CPU/VM without AVX2 | use UBI 9 (default) |
| `cd: .../.puppetlabs/etc/puppet: No such file or directory` at first start | missing `/etc/puppetlabs/puppet` | fixed in `finalize-image.sh` (`install -d ... /etc/puppetlabs/puppet/ssl`) |
| `Could not find 'io-console'` from `eyaml` | RHEL ships io-console separately; wrapper GEM_PATH dropped system gems | `rubygem-io-console` installed; wrapper appends `$(gem env gempath)` |
| `ln: ... irb -> ''` during build | irb/erb are separate RPMs on RHEL | build links only tools that exist |
| `cp: preserving times for '/etc/puppetlabs/.': Operation not permitted` | seed tried to modify the root-owned mount point | seed copies entries, never the mount point |
| `cp: unrecognized option '--update=none'` | UBI 9 coreutils 8.32 | seed script copies file by file (portable) |
| `Cannot determine basic system flavour` / `cannot load such file -- puppet` | `/tmp` mounted `noexec`; JRuby loads a native lib from `/tmp` | `/tmp` must allow exec (`emptyDir` does; `--tmpfs /tmp:exec` locally) |
| `Failed to open TCP connection to puppet:8140` from `puppetserver ca ...` | `CA_HOSTNAME` (default `puppet`) does not resolve in the pod | set `CA_HOSTNAME` to a resolvable name (Discovery) |
| Catalog test returns `Operator '[]' is not applicable to an Undef Value` | test request sent no facts | test manifests must not use `$facts`; not a server problem |
| Changed manifest has no effect | `OPENVOXSERVER_ENVIRONMENT_TIMEOUT=unlimited` caches environments | use a new environment name for tests, or the env-cache delete API |
| CA signing returns HTTP 500 `.../ca/serial...tmp: Operation not permitted` | files still owned by the old UID 999; fsGroup only changes the group | run the `chown -R 64604:64604` step (Phase 8 step 3) |
| curl reports certificate name mismatch in tests | used `localhost` instead of the certname | `curl --resolve <certname>:8140:127.0.0.1 https://<certname>:8140/...` |
| `docker build` says `open Dockerfile: no such file` | Docker doesn't read `Containerfile` by default | `docker build -f Containerfile ...` (podman needs nothing) |
| Policy check flags the maintenance pod | it runs as root by design | it lives in `k8s/migration/`, which scans skip; never deploy it permanently |
| Image has HEALTHCHECK missing in podman | built in OCI format | `podman build --format docker` |
| Helm upgrade: PVCs show `is being deleted` / pod Pending `persistentvolumeclaim ... not found` | chart's non-root mode makes PVCs pre-install hooks; Helm deletes them on upgrade | **STOP**. Never run the upgrade without the post-renderer and the H4 step 1b `keep` annotation |
| Helm upgrade: pod Pending, `...-puppetserver-claim not found` | chart creates that PVC only on first install | post-renderer uses an emptyDir there; make sure it ran (`$POST`) |
| Helm upgrade fails: `spec.strategy.rollingUpdate: Forbidden ... 'Recreate'` | switching to Recreate under server-side apply | use the `values-hardened.yaml` strategy (RollingUpdate, maxSurge 0) |
| Server stays at 0 replicas after `helm upgrade` | chart has no `replicas` for a single master; handover scaled it to 0 | post-renderer pins `replicas: 1`; manual fix `kubectl scale deploy ... --replicas=1` |
| r10k sidecar: `can't create /home/puppet/...`, `/etc/passwd`, `/etc/puppetlabs/r10k/r10k.yaml: Read-only file system` | r10k image writes to its root filesystem at startup | post-renderer r10k patch (emptyDirs + passwd init container) |
| CA signing fails after the Helm upgrade, HTTP 500 `Operation not permitted` | old image left CA files owned by 999:999 | `scripts/k8s-handover-volumes.sh` (H4 step 2) |
| DB pod: `Permission denied` on `certs/private_keys/server.key` | PuppetDB SSL files are `0600` owned by 999 (KNOWLEDGE K2) | hand the DB PVC over too |
| DB connects to an empty database / requests a new certificate | renamed env vars fell back to OpenVoxDB defaults (`openvoxdb`) (K16) | set `OPENVOXDB_POSTGRES_DATABASE`, `..._USER`, `CERTNAME` to the old values |
| Policy check reports CKV_K8S_28/37 but Checkov does not | old offline checker compared `drop: [all]` case-sensitively | fixed: the checker now ignores case, like Checkov |

---

## Appendix A: How the image works

- **User:** `puppet`, UID 64604, GID 64604 in `/etc/passwd`; the image runs as `64604:0`. Writable
  dirs are owned by 64604 with group 0 and group = owner rights (OpenShift random UIDs also work).
- **Writable paths** (`rootfs/usr/local/share/openvox/writable-dirs`): `/etc/puppetlabs`,
  `/opt/puppetlabs/server/data/puppetserver`, `/opt/puppetlabs/puppet/cache`, `/var/log/puppetlabs`,
  `/run/puppetlabs`, `/run/openvox`; plus `/tmp` (exec). Pristine copies are in
  `/usr/share/openvox-seed`; `00-seed-writable-dirs.sh` copies **missing** entries only.
- **Startup order:** `/container-entrypoint.sh` (upstream) → `/container-entrypoint.d/*.sh` in
  order (`00-seed` is ours, the rest upstream) → `puppetserver foreground`.
- **Gems:** system Ruby gems (`openvox`, `openvoxserver-ca`, `hocon`, `r10k`) in `/usr/local/share/gems`;
  JRuby gems (`openvox`, `hiera-eyaml`, vendored gems) under `/opt/puppetlabs/server/apps/puppetserver/`.
- **Removed RPMs** (`UNUSED_RPMS`): python3 stack, crypto-policies-scripts, cups-libs, avahi-libs,
  microdnf and its libraries. Consequence: no package manager in the final image (rebuild instead of patching in place).

## Appendix B: migration-report.md template

```markdown
# OpenVox migration report
Date: / Operator: / Agent:

## Preflight
podman version: / arch: / UBI tag: / artifacts reachable:

## Discovery
| Fact | Value |
|---|---|
| Namespace / kind / name | |
| Old image (digest) | |
| PVCs (name, size, class, mount path) | |
| ConfigMap/Secret mounts | |
| Env vars (names) | |
| Service name / selector | |
| Server certname | |
| CA fingerprint | |
| Signed cert count | |
| CA_HOSTNAME resolves | |
| OpenVoxDB used / version | |
| r10k used | |
Operator "go" (gate 1): <name, time>

## Build
build args: / image ID: / build.log tail:

## Functional tests
smoke-test.log (full):

## Scans
scan.log summary: / Aqua summary: / accepted exceptions (CVE, package, reason):

## Push
image@digest: / operator approval (gate 2):

## Manifest
diff summary vs old: / policy result: / dry-run result:

## Staging rehearsal
approval (gate 3): / verify outputs: / rollback rehearsal: / durations:

## Production cutover
approval (gate 4): / backup file + sha256: / verify outputs: / canary agents:

## Rollback (if any)
## Open items
```

## Appendix C: Reference results (2026-10-19, arm64 test host, Trivy 0.76.0)

| Image | Critical | High | Medium | Low | Total | Fixable |
|---|---|---|---|---|---|---|
| ghcr.io/openvoxproject/openvoxserver:8.8.1-v1.0.0 | 2 | 13 | 480 | 132 | 627 | 565 |
| ghcr.io/openvoxproject/openvoxserver:8.17.0 | 0 | 30 | 2709 | 86 | 2825 | 13 |
| **openvox-server-ubi:8.17.0 (UBI 9.8, default)** | 0 | 18 | 182 | 128 | 328 | **0** |
| openvox-server-ubi:8.17.0 (UBI 10.2) | 0 | 1 | 0 | 0 | 1 | 0 |

Example findings from the operator's Aqua report on the deployed 8.8.1 image, checked against the new image:

| Finding (8.8.1) | Where it comes from in 8.8.1 | New image |
|---|---|---|
| CVE-2026-54906, concurrent-ruby 1.2.3 (critical) | gems 1.2.3 and 1.3.5 (fix ≥ 1.3.7) | concurrent-ruby **1.3.8**: not present |
| CVE-2026-8927, curl 8.20.0 | curl vendored by the all-in-one agent under `/opt/puppetlabs/puppet/bin` (Trivy reports Ubuntu's libcurl instead) | only Red Hat's `curl-minimal`/`libcurl-minimal`: not present |
| CVE-2026-10050, jetty-security 10.0.20 | Jetty 10 shaded into `puppet-server-release.jar` | openvox-server 8.17 ships **Jetty 12.1.12**: not present |

Note: the reference `8.8.1-v1.0.0` image contains vendored curl **8.13.0**, the operator's Aqua
report shows **8.20.0**, so the deployed 8.8.1 is a later rebuild. Always use the exact deployed
image (digest from Phase 1 / H1) for the migration tests.

Policy: Checkov 3.3.20 (container): 89 passed, 1 failed (CKV_K8S_43) before the digest is set; 90 passed, 0 failed with a digest. Offline checker: 21/1 and 22/0.
Functional: all smoke tests passed for both UBI 9 and UBI 10, including migration from
`8.8.1-v1.0.0` and rollback. Not yet tested by the reference run: an **amd64** build (UBI 9 needs
no special CPU features), podman itself (the reference run used Docker with the same scripts),
Path M on a real cluster (Path H was run on local k3s, see below), real agents. Those happen in
Phases 2–8 / H1–H4.

Helm path (local k3s v1.35, OpenVox chart 11.0.0, Helm 4.3, r10k pulling a public control repo),
`scripts/helm-migration-test.sh` from root-mode `8.8.1-v1.0.0` (CA files owned 999:999):
`ALL HELM MIGRATION TESTS PASSED`, i.e. PVCs kept with the same UIDs, CA unchanged, signing works
as UID 64604 with a read-only root, r10k deploy works, `helm rollback` keeps CA and signing.
A variant without the live `keep` annotation also kept the PVCs (post-renderer alone); its CA
checks in that run were inconclusive (a test-script exec error), so H4 keeps both safeguards.
Checkov on the hardened render: the server Deployment has no CKV_K8S_22/40/9 failures; remaining
there: CKV_K8S_38 (chart mounts the service-account token), CKV_K8S_8 (no liveness probe on the
r10k sidecar), CKV_K8S_43 until the r10k image is digest-pinned too (`global.r10k.tag: "<tag>@sha256:..."`).
PuppetDB and PostgreSQL still fail CKV_K8S_22/40 (not covered).
Before the fixes, the rehearsal reproduced: PVC deletion on upgrade, pod Pending on the missing
`puppetserver-claim`, the `Recreate` rejection, 0 replicas after handover, r10k failing on a
read-only root, and CA signing failing on 999-owned files.

## Appendix D: UBI 10 option

`podman build --format docker --build-arg UBI_MAJOR=10 --build-arg UBI_TAG=10.2 -t ... .`
reduces findings to ~1 but requires **x86-64-v3 (AVX2)** on every amd64 build host and cluster node.
Check each node: `grep -o avx2 /proc/cpuinfo | head -1` must print `avx2`. VMs with generic CPU
models (KVM `qemu64`, old VMware EVC baselines) often don't. Everything else in this document
applies unchanged.
