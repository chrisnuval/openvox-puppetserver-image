# HANDOVER.md: checks for a successful ownership handover

How to move the persistent volumes of an existing OpenVox/Puppet deployment from the old images'
user (**999:999**, or root) to the new images' user (**64604:64604**) without losing the CA,
signed certificates or PuppetDB data, and how to **prove** it worked. Companion to AGENT.md (H4,
C5) and KNOWLEDGE.md (K2).

The commands are samples: adapt names, labels and paths to the deployment found in discovery. The
outputs below are **real**, from a rehearsal on k3s (2026-10-19): the public OpenVox chart 11.0.0 in
root mode with `openvoxserver:8.8.1-v1.0.0` and 3 signed agent certificates, plus a PuppetDB
deployment like a company fork's: `voxpupuli/puppetdb:8.8.1-v1.7.0` as root with a metrics
sidecar as UID 999 sharing its volume. Use another UID only if you build the images with it
(`--build-arg OPENVOX_USER_UID=... OPENVOX_USER_GID=...`) and use it everywhere.

Rules: steps 1-3 are read-only. Step 4 needs operator approval (root pod, downtime). Never print
private keys; hashes of public keys and certificate fingerprints are fine.

---

## Step 1. Inventory: every PVC, every container that mounts it, every UID

Ownership must match **every** container that touches a volume, not only the main one:
init containers, sidecars (r10k, metrics exporters, dashboards, CRL updaters) and jobs.

`pvc-inventory.tmpl` (kubectl go-template, no other tools needed):
```
{{- range .items}}{{$w := printf "%s/%s" .kind .metadata.name}}{{$spec := .spec.template.spec}}
{{- $pu := "unset"}}{{with $spec.securityContext}}{{$pu = printf "%v" .runAsUser}}{{end}}
{{- range $spec.volumes}}{{if .persistentVolumeClaim}}{{$vn := .name}}{{$claim := .persistentVolumeClaim.claimName}}
{{- range $spec.initContainers}}{{$c := .}}{{range .volumeMounts}}{{if eq .name $vn}}{{$w}}	init:{{$c.name}}	{{$claim}}	{{.mountPath}}	{{with $c.securityContext}}{{printf "%v" .runAsUser}}{{else}}unset{{end}}	{{$pu}}
{{end}}{{end}}{{end}}
{{- range $spec.containers}}{{$c := .}}{{range .volumeMounts}}{{if eq .name $vn}}{{$w}}	{{$c.name}}	{{$claim}}	{{.mountPath}}	{{with $c.securityContext}}{{printf "%v" .runAsUser}}{{else}}unset{{end}}	{{$pu}}
{{end}}{{end}}{{end}}{{end}}{{end}}{{end}}
```
```bash
{ printf 'WORKLOAD\tCONTAINER\tPVC\tMOUNT\tCTR_UID\tPOD_UID\n'
  kubectl get deploy,statefulset,cronjob -n "$NS" -o go-template-file=pvc-inventory.tmpl; } | column -t -s $'\t'
```
Output:
```
WORKLOAD                                         CONTAINER            PVC                            MOUNT                                 CTR_UID  POD_UID
Deployment/ovx-puppetserver-puppetserver-master  ovx-puppetserver     ovx-puppetserver-code-claim    /etc/puppetlabs/code/                 <nil>    <nil>
Deployment/ovx-puppetserver-puppetserver-master  ovx-puppetserver     ovx-puppetserver-ca-claim      /etc/puppetlabs/puppetserver/ca/      <nil>    <nil>
Deployment/ovx-puppetserver-puppetserver-master  init:perms-and-dirs  ovx-puppetserver-puppet-claim  /etc/puppetlabs/puppet/               0        <nil>
Deployment/ovx-puppetserver-puppetserver-master  ovx-puppetserver     ovx-puppetserver-puppet-claim  /etc/puppetlabs/puppet/               <nil>    <nil>
Deployment/puppetdb                              metrics-exporter     puppetdb-data                  /opt/puppetlabs/server/data/puppetdb  999      unset
Deployment/puppetdb                              puppetdb             puppetdb-data                  /opt/puppetlabs/server/data/puppetdb  unset    unset
```
How to read it: `<nil>`/`unset` = the image's default user (**root** for the 8.8.1 images, which
then switch to 999 inside). `0` = explicit root (the chart's init container, CKV_K8S_40). Record
for the plan: every PVC, and every container that must run as 64604 afterwards (here: the server,
PuppetDB **and** `metrics-exporter`). A CronJob, or a Job from a hook, that mounts these PVCs counts too.

## Step 2. Ownership census and owner-only files

Run inside the **running old pods** (they run as root and have GNU find), one line per mount path
from step 1:
```bash
census='for p in "$@"; do echo "== $p"; find "$p" -xdev -printf "%U:%G\n" | sort | uniq -c; done'
kubectl -n "$NS" exec "$SERVER_POD" -c "$SERVER_CTR" -- bash -c "$census" _ \
  /etc/puppetlabs/puppetserver/ca /etc/puppetlabs/puppet /etc/puppetlabs/code
kubectl -n "$NS" exec "$DB_POD" -c puppetdb -- bash -c "$census" _ /opt/puppetlabs/server/data/puppetdb
```
Output:
```
== /etc/puppetlabs/puppetserver/ca
     18 999:999
== /etc/puppetlabs/puppet
      1 0:999
     29 999:999
== /etc/puppetlabs/code
      1 0:64604
== /opt/puppetlabs/server/data/puppetdb
     27 999:999
```
Mixed owners are normal (root-owned mount points, files written by init containers). Owner-only
files show who would lose access without the handover:
```bash
kubectl -n "$NS" exec "$DB_POD" -c puppetdb -- find /opt/puppetlabs/server/data/puppetdb -xdev -type f \
  -perm -u=r ! -perm -g=r -printf '%m %U:%G %p\n'
```
```
600 999:999 /opt/puppetlabs/server/data/puppetdb/stockpile/cmd/stockpile
600 999:999 /opt/puppetlabs/server/data/puppetdb/certs/private_keys/server.private_key.pk8
600 999:999 /opt/puppetlabs/server/data/puppetdb/certs/private_keys/puppetdb.pem
...
```

## Step 3. Baseline (compare after the handover and after a rollback)

`baseline-server.sh` (piped into the server pod with `kubectl exec -i ... -- bash -s < baseline-server.sh`):
```bash
ca=/etc/puppetlabs/puppetserver/ca
echo "ca_crt      $(openssl x509 -noout -fingerprint -sha256 -in $ca/ca_crt.pem | cut -d= -f2)"
echo "ca_key      $(openssl pkey -in $ca/ca_key.pem -pubout | sha256sum | cut -c1-16)  (public key hash; the key itself is never printed)"
echo "signed      $(ls $ca/signed | wc -l)"
echo "inventory   $(wc -l < $ca/inventory.txt)"
echo "serial      $(cat $ca/serial)"
echo "crl         $(openssl crl -noout -crlnumber -in $ca/ca_crl.pem)"
```
`baseline-db.sh` (into the PuppetDB container):
```bash
d=/opt/puppetlabs/server/data/puppetdb/certs
echo "db_cert     $(openssl x509 -noout -fingerprint -sha256 -in $d/certs/server.crt | cut -d= -f2)"
echo "nodes       $(curl -s http://localhost:8080/pdb/query/v4/nodes | grep -o '"certname"' | wc -l)"
echo "status      $(curl -s http://localhost:8080/status/v1/services/puppetdb-status | grep -o '"state" *: *"[a-z]*"')"
```
```bash
kubectl -n "$NS" exec -i "$SERVER_POD" -c "$SERVER_CTR" -- bash -s < baseline-server.sh | tee server-before.txt
kubectl -n "$NS" exec -i "$DB_POD" -c puppetdb -- bash -s < baseline-db.sh | tee db-before.txt
```
Output:
```
ca_crt      9B:71:88:4A:16:D8:4B:37:4A:98:B7:AF:F8:05:01:E3:8F:21:A5:22:30:55:6C:31:71:6D:0B:A2:FF:76:32:8C
ca_key      46a2e1ef9b3b681f  (public key hash; the key itself is never printed)
signed      5
inventory   5
serial      0006
crl         crlNumber=0x00
db_cert     8A:9B:FD:38:0E:A6:81:66:FB:F6:01:69:23:A4:CF:09:2B:E3:35:AA:2D:0D:8F:CA:9F:AC:97:97:47:17:3B:9A
nodes       3
status      "state":"running"
```
(5 signed = server, 3 agents, PuppetDB.) Also take the backups now: `tar` of every PVC path and a
`pg_dump` of the PuppetDB database (AGENT.md H4 step 1); the handover changes no content, the
OpenVoxDB upgrade migrates the database schema.

## Step 4. Handover (operator approval: downtime + root pod)

1. Stop **every** workload from step 1 that mounts the PVCs (ReadWriteOnce, and nothing may write
   during the change), and wait until the pods are gone:
   ```bash
   kubectl -n "$NS" scale deploy/ovx-puppetserver-puppetserver-master deploy/puppetdb --replicas=0
   kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/component=puppetserver --timeout=5m
   kubectl -n "$NS" wait --for=delete pod -l app=puppetdb --timeout=5m
   ```
2. One root maintenance pod from the **old** image (already approved in the cluster; has
   `chown`/`find`) with every PVC mounted (one pod can mount several RWO PVCs):
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata: {name: openvox-maint}
   spec:
     restartPolicy: Never
     automountServiceAccountToken: false
     containers:
       - name: maint
         image: ghcr.io/openvoxproject/openvoxserver:8.8.1-v1.0.0   # the exact old image (digest)
         command: [sleep, infinity]
         securityContext: {runAsUser: 0}
         volumeMounts:
           - {name: ca, mountPath: /v/ca}
           - {name: puppet, mountPath: /v/puppet}
           - {name: code, mountPath: /v/code}
           - {name: pdb, mountPath: /v/puppetdb}
     volumes:
       - {name: ca, persistentVolumeClaim: {claimName: ovx-puppetserver-ca-claim}}
       - {name: puppet, persistentVolumeClaim: {claimName: ovx-puppetserver-puppet-claim}}
       - {name: code, persistentVolumeClaim: {claimName: ovx-puppetserver-code-claim}}
       - {name: pdb, persistentVolumeClaim: {claimName: puppetdb-data}}
   ```
3. Check the storage accepts `chown` (NFS with root squash does not), change, verify:
   ```bash
   kubectl -n "$NS" exec openvox-maint -- bash -c '
   echo "== storage accepts chown?"; for v in /v/*; do t=$v/.chown-test; touch $t && chown 64604:64604 $t && stat -c "%u:%g $v" $t; unlink $t; done
   echo "== chown"; chown -R 64604:64604 /v/* && echo done
   echo "== files NOT owned by 64604:64604 (expected 0 per volume)"
   for v in /v/*; do echo "$(find $v -xdev \( ! -uid 64604 -o ! -gid 64604 \) | wc -l)  $v"; done'
   kubectl -n "$NS" delete pod openvox-maint --wait
   ```
   Output:
   ```
   == storage accepts chown?
   64604:64604 /v/ca
   64604:64604 /v/code
   64604:64604 /v/puppet
   64604:64604 /v/puppetdb
   == chown
   done
   == files NOT owned by 64604:64604 (expected 0 per volume)
   0  /v/ca
   0  /v/code
   0  /v/puppet
   0  /v/puppetdb
   ```
   If the storage check fails: **STOP**, scale the old workloads back up, report.
   (For a single Deployment, `scripts/k8s-handover-volumes.sh` does 1-3 for the PVCs mounted in its
   main container; for several workloads or sidecar-only volumes use the pod above.)

## Step 5. Start the new images

Server: `helm upgrade` with the hardened values (AGENT.md H4; with your own chart: your updated
templates). PuppetDB: the new image with the old settings under the new names (KNOWLEDGE.md K16:
`CERTNAME`, database, user, allowlist), `runAsUser: 64604`, and **every container from step 1 that
shares the volume** moved to 64604 as well.

Verify the PVCs were not replaced (same `VOLUME` names / UIDs as before the upgrade):
```
NAME                            STATUS   VOLUME
ovx-puppetserver-ca-claim       Bound    pvc-7368095f-f6a2-4428-a99c-77fd2e5de7ee
ovx-puppetserver-code-claim     Bound    pvc-f3a27862-d007-4bb5-918b-c0b33856ea5c
ovx-puppetserver-puppet-claim   Bound    pvc-e1037310-bc7f-4a93-8cfb-da6def5a7bb3
puppetdb-data                   Bound    pvc-ab1f9a7a-1ac5-4319-b47d-fe8ccca21e5f
```

## Step 6. Post-checks (all must pass)

```bash
echo "== 1. every container's UID"
for p in "$SERVER_POD" "$DB_POD"; do for c in $(kubectl -n "$NS" get "$p" -o jsonpath='{.spec.containers[*].name}'); do
  echo "$p/$c: $(kubectl -n "$NS" exec "$p" -c "$c" -- id -u)"; done; done
echo "== 2. baseline diff"
kubectl -n "$NS" exec -i "$SERVER_POD" -- bash -s < baseline-server.sh > server-after.txt; diff server-before.txt server-after.txt && echo "server: identical"
kubectl -n "$NS" exec -i "$DB_POD" -c puppetdb -- bash -s < baseline-db.sh > db-after.txt; diff db-before.txt db-after.txt && echo "puppetdb: identical"
echo "== 3. each container can write where it must"
kubectl -n "$NS" exec "$SERVER_POD" -- bash -c 'for d in /etc/puppetlabs/puppetserver/ca /etc/puppetlabs/puppetserver/ca/signed /etc/puppetlabs/puppet/ssl /etc/puppetlabs/code; do test -w $d && echo "ok   writable $d" || echo "FAIL not writable $d"; done; test -w /etc/puppetlabs/puppetserver/ca/serial && echo "ok   writable serial"'
kubectl -n "$NS" exec "$DB_POD" -c puppetdb -- bash -c 'd=/opt/puppetlabs/server/data/puppetdb; test -w $d && echo "ok   writable $d"; test -r $d/certs/private_keys/server.key && echo "ok   readable server.key"'
echo "== 4. the CA can still sign"
kubectl -n "$NS" exec "$SERVER_POD" -- puppetserver ca generate --certname handover-test.invalid
kubectl -n "$NS" exec "$SERVER_POD" -- puppetserver ca clean --certname handover-test.invalid
echo "== 5. sidecars sharing a volume: run their own access check (here: the exporter's log)"
kubectl -n "$NS" logs "$DB_POD" -c metrics-exporter --tail=1
```
Output:
```
== 1. every container's UID
pod/ovx-puppetserver-puppetserver-master-5d555b76f6-m45lk/ovx-puppetserver: 64604
pod/puppetdb-68d6964756-7jsg8/metrics-exporter: 999
pod/puppetdb-68d6964756-7jsg8/puppetdb: 64604
== 2. baseline diff
server: identical
puppetdb: identical
== 3. each container can write where it must
ok   writable /etc/puppetlabs/puppetserver/ca
ok   writable /etc/puppetlabs/puppetserver/ca/signed
ok   writable /etc/puppetlabs/puppet/ssl
ok   writable /etc/puppetlabs/code
ok   writable serial
ok   writable /opt/puppetlabs/server/data/puppetdb
ok   readable server.key
== 4. the CA can still sign
Certificate for handover-test.invalid was autosigned.
Cleaned files related to handover-test.invalid
== 5. sidecars sharing a volume
key-readable
```
How to judge it:
- Run check 2 **before** check 4. The signing test (sign + clean) legitimately advances the CA's
  bookkeeping, so a later baseline diff shows (real output from a re-run after the test):
  ```
  < inventory   5
  < serial      0006
  < crl         crlNumber=0x00
  ---
  > inventory   6
  > serial      0007
  > crl         crlNumber=0x01
  ```
  That is expected. `ca_crt`, `ca_key` and `signed` must never change.
- **Check 1 found a problem the others did not:** `metrics-exporter` still runs as **999**. It can
  read the key only because the pod has `fsGroup: 64604`: at mount, Kubernetes re-grouped the
  volume to 64604 and added group read/write (the key went from `600` to `660`), and every
  container in the pod gets 64604 as a supplementary group. Remove `fsGroup` (or let a script
  `chmod g=` the key, as PuppetDB's `ssl.sh` does when it creates certificates) and the sidecar
  loses access. And UID 999 still fails CKV_K8S_40. Fix: run it as 64604 too.
- **Check 4 is the one that matters most** for the server: reading works with `fsGroup` alone, but
  signing rewrites `serial`/`inventory.txt` keeping the file owner, which only the owner can do.
  Without the handover this fails with HTTP 500 `Operation not permitted` (reproduced in the
  rehearsal with `fsGroup` set).
- Then: 1-3 canary agents `puppet agent -t` (catalog applied, no SSL errors; reports appear in
  PuppetDB), `kubectl get events` shows no probe failures.
- `fsGroupChangePolicy: OnRootMismatch`: the first start after the handover still does one
  recursive group change (the volume root lacks the setgid bit); later starts skip it. On large
  volumes the first start takes longer.

## Rollback

Same as step 4 in reverse, with the new workloads scaled to 0: `chown -R 999:999` (verify with
`! -uid 999 -o ! -gid 999` = 0), restore the `pg_dump` into a fresh database (the OpenVoxDB start
migrated the schema forward), start the old workloads, re-run step 6 checks 2 and 4 against
`*-before.txt`. Tested: `scripts/openvoxdb-test.sh` (PuppetDB) and `scripts/helm-migration-test.sh` (server).
