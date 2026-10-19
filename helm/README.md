# Helm: OpenVox chart + openvox-server-ubi

For the [OpenVox Helm chart](https://github.com/OpenVoxProject/openvox-helm-chart) (tested with
chart 11.0.0). Two pieces, always used together:

| File | What it does |
|---|---|
| `values-hardened.yaml` | `global.runAsNonRoot: true` (no root init container, server as UID 64604: **CKV_K8S_40**), image, pull policy, resources, one-at-a-time update strategy (`maxSurge: 0`), r10k sidecar `readOnlyRootFilesystem` |
| `post-render/` | Kustomize patches for what the chart can't configure: read-only root for the server (**CKV_K8S_22**), scratch volumes, the image's own entrypoint, removal of the root pre-install Job, and the r10k sidecar fixes below |

## Use

    # Helm 3
    helm upgrade --install <release> <chart> -n <ns> -f <your-values.yaml> -f helm/values-hardened.yaml \
      --post-renderer ./helm/post-render/post-render.sh

    # Helm 4 (post-renderers are plugins)
    helm plugin install ./helm/post-render          # once; reinstall after editing post-render/
    helm upgrade --install ... --post-renderer openvox-hardening

    # GitOps / inspection
    helm template <release> <chart> -n <ns> -f ... | helm/post-render/post-render.sh > manifests.yaml

Needs `kubectl` (built-in kustomize) or `kustomize` on the machine running Helm.
Put `values-hardened.yaml` **after** your own values file and set your registry/digest in it.

## Read this before upgrading an existing release

1. **The chart deletes your PVCs (CA included) when you switch `global.runAsNonRoot` on.** In
   non-root mode every PVC becomes a `pre-install` hook; hooks are not release resources, so
   `helm upgrade` from root mode removes them. The post-renderer keeps them as normal resources with
   `helm.sh/resource-policy: keep`. As a second safeguard, annotate the live PVCs first:
   `kubectl annotate pvc -n <ns> -l app.kubernetes.io/instance=<release> helm.sh/resource-policy=keep`.
   Never run the upgrade without the post-renderer.
2. **Hand the volumes over once** (`scripts/k8s-handover-volumes.sh`): the 8.8.1 image leaves the CA
   files owned by 999:999; the new server (UID 64604) can't sign certificates on them.
3. **Rehearse** with `scripts/helm-migration-test.sh` in a throwaway namespace.
The full procedure is AGENT.md, Path H.

## What the post-renderer changes and why

**Puppet server Deployment** (`app.kubernetes.io/component=puppetserver`)
- `readOnlyRootFilesystem: true`, pod `runAsNonRoot`, seccomp `RuntimeDefault`.
- Removes the chart's `command`/`args` (`exec puppetserver foreground`), so the image's entrypoint
  runs: environment-variable configuration (`DNS_ALT_NAMES`, autosign, ...) and filling empty
  volumes from the image.
- emptyDirs for `/tmp`, `/opt/puppetlabs/puppet/cache`, `/var/log/puppetlabs`, `/run/puppetlabs`,
  `/run/openvox`, and the data dir unless `puppetserver.persistence.data.enabled` mounts a PVC there.
- Pins `replicas: 1` (the chart sets replicas only for multi-master; after the handover the
  Deployment is at 0 and would stay there).
- `/etc/puppetlabs/puppetserver` becomes an emptyDir instead of the non-root-mode PVC: the image
  regenerates that config from env vars at every start (as root mode always did; the CA keeps its
  own PVC). The chart creates that PVC only on first install, so on upgrade the pod stayed Pending.
  The unused PVC is removed from the render.

**PVCs**: hook annotation removed, `helm.sh/resource-policy: keep` added (see above).

**Pre-install Job** (`*-puppet-preinstall`): deleted. It runs as root to copy config into the
volumes on first install; the image does this itself at startup as UID 64604.

**r10k sidecars** (`r10k-code` / `r10k-hiera`, only when configured): the r10k image's startup
scripts write to the root filesystem, so with a read-only root every deploy failed. The patch adds
- emptyDirs for `/tmp`, `/home/puppet` (crontab, logs) and `/etc/puppetlabs/r10k` (a default
  `r10k.yaml` the chart doesn't use; the chart passes its own `--config`);
- an `/etc/passwd` with an entry for UID 64604, written by a small non-root, read-only init
  container from the same r10k image. Without it, `05-add_passwd_entry.sh` tries to append to
  `/etc/passwd` and aborts the deploy.

## Results (local k3s v1.35, chart 11.0.0, r10k pulling a public control repo)

- Server: Ready, UID 64604, read-only root, catalog of the r10k-deployed `production` environment
  compiles, CA signs and cleans certificates.
- r10k sidecar: UID 64604, read-only root, `r10k deploy` exit 0.
- Checkov on the deployed release: no CKV_K8S_22 / CKV_K8S_40 / CKV_K8S_9 failures.
  Remaining on the server Deployment: CKV_K8S_43 (set the digest), CKV_K8S_38 (chart mounts the
  service account token), CKV_K8S_8 (chart defines no liveness probe for the r10k sidecar).

**Not covered here:** the chart's PuppetDB Deployment (openvoxdb image) and the Bitnami PostgreSQL
subchart still fail CKV_K8S_22/40; they need their own hardening (or are disabled /
external).
