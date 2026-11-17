# kubevirt-gitops

This repository is an example of managing KubeVirt virtual machines
and datavolumes using a GitOps workflow, specifically using ArgoCD
as provided by OpenShift GitOps.

Where possible, namespaces and resource names have been left variable
for portability, but since this is in support of an OpenShift blog,
the default leans to OpenShift products and namespaces.

## Get Started

On an OpenShift cluster with OpenShift Virtualization and OpenShift GitOps:

1. Configure the GitOps operator's instance: Argo CD health checks for KubeVirt kinds and a 6Gi
   memory limit for the application controller (the default 2Gi gets OOMKilled on clusters with
   many CRDs): `oc apply -k gitopsservice/argocd` (see [gitopsservice](gitopsservice/README.md)).
2. Let that instance manage the two namespaces the builds write to. The default `openshift-gitops`
   instance can read the whole cluster but only write where a namespace carries its
   `managed-by` label; without it, syncs hang on the first Job, CronJob or DataVolume:

   ```
   oc create namespace kubevirt-gitops
   oc label namespace kubevirt-gitops openshift-virtualization-os-images argocd.argoproj.io/managed-by=openshift-gitops
   ```

   The GitOps operator then gives the instance's application controller full rights in those
   namespaces. It needs them for the build's RoleBindings to `admin` and
   `os-images.kubevirt.io:edit` too: Kubernetes only lets it bind roles whose permissions it holds.
3. Deploy the boot sources from your environment's config repository, which holds the overlays
   and the ApplicationSet (see [Deploying from a config repo](#deploying-from-a-config-repo)).

## Repository layout

| Path | What it is |
|---|---|
| [windows/build](windows/build) | Shared Windows boot-source build (Kustomize Component) |
| `win10`, `win11`, `win2k16`, `win2k19`, `win2k22`, `win2k25` | One Windows version each: build parameters (`base/`); environments add their overlays from a config repo |
| [datavolumes](datavolumes) | Fedora and CentOS Stream cloud-image DataVolumes |
| [vms](vms) | Demo Fedora and CentOS VMs cloned from DataSources |
| [examples](examples) | VirtualMachinePool demos and a Windows example VM per version and an example environment (`examples/environment`) |
| [gitopsservice](gitopsservice) | OpenShift GitOps settings: Argo CD health checks, namespace label, controller memory, infra placement |
| [docs](docs) | [Architecture review and improvement tracker](docs/architecture-review.md), [fork survey](docs/upstream-fork-survey.md) |

### DataVolumes

The [datavolumes](datavolumes) directory imports Fedora and CentOS Stream cloud images into
`openshift-virtualization-os-images` (`oc apply -k datavolumes/overlays/openshift`).

### Virtual Machines

The [vms](vms) directory creates a Fedora and a CentOS Stream VM. They have no passwords: create
the `vm-ssh-key` Secret first (see [vms/README.md](vms/README.md)).

### Microsoft Windows boot sources

Each Windows directory builds the boot-source PVC in `openshift-virtualization-os-images` that the
matching OpenShift Virtualization templates clone:

| Directory | Version | Boot source / DataSource | Job |
|---|---|---|---|
| `win10` | Windows 10 Pro | `win10` | `windows-10-install` |
| `win11` | Windows 11 Pro | `win11` | `windows-11-install` |
| `win2k16` | Windows Server 2016 Standard (Desktop Experience) | `win2k16` | `windows-2k16-install` |
| `win2k19` | Windows Server 2019 Standard (Desktop Experience) | `win2k19` | `windows-2k19-install` |
| `win2k22` | Windows Server 2022 Standard (Desktop Experience) | `win2k22` | `windows-2k22-install` |
| `win2k25` | Windows Server 2025 Standard (Desktop Experience) | `win2k25` | `windows-2k25-install` |

The build is written once, in [windows/build](windows/build). Each version only supplies its
parameters:

```
windows/build/                  # Kustomize Component, shared by every version
  windows-install-{sa,rbac,job}.yaml
  windows-rebuild-cronjob.yaml  # monthly rebuild (suspended unless the environment turns it on)
windows/environment/            # Kustomize Component: an environment's ISO_BASE_URL -> ISO URLs
  config/                       # -> ConfigMap windows-<OS>-install-scripts
    install.sh                  #    build, check, store, publish (Job and CronJob)
    windows-install-vm.yaml     #    build VM template (@PLACEHOLDERS@ filled from os.env)
    windows-verify-vm.yaml      #    throwaway clone that checks the image before it is published
    clone-boot-source.yaml      #    DataVolume into openshift-virtualization-os-images
    autounattend.xml            #    unattended install; desktop/server and product-key blocks
    post-install.ps1            #    virtio-win, guest agent, cloudbase-init, Windows Update, sysprep
winXX/
  base/
    os.env                      # this version's parameters -> ConfigMap windows-<OS>-install-params
    install-iso.yaml            # DataVolume importing the install ISO over HTTP
    kustomization.yaml          # install-iso + params + components: [../../windows/build]
examples/environment/           # an example environment: settings/ + overlays/winXX
```

`os.env` holds what differs between versions: the name key (`OS`), boot-source name, OS label,
desktop or server edition, virtio-win driver folder, image selector (`/IMAGE/NAME` for desktop,
`/IMAGE/INDEX` 2 for Server with Desktop Experience), generic product key, TPM, disk size and
Windows Update limits. To add a version, copy a `winXX/` directory, edit `os.env` and
`install-iso.yaml`; environments add an overlay for it in their config repo.

What every build does:

- **Fail fast.** `install.sh` follows `C:\Windows\Temp\build-status.txt` through the guest agent.
  It fails the Job on a reported failure, on no progress for `STALL_MIN` minutes, or on a
  shutdown before sysprep.
- **No stored password.** The Administrator password is random for each build and never logged.
  The build's auto-logon is removed before sysprep, and clones get their identity from
  sysprep/cloudbase-init or the template.
- **Patched image.** Windows Update runs in rounds (drivers and feature upgrades excluded) until
  nothing is left.
- **Clone-ready disk.**
  - The build VM uses a virtio NIC; post-install installs NetKVM from virtio-win before it needs
    the network. The virtio storage and NIC drivers are checked to be in the driver store.
  - WinRE sits before C:, so clones grow C: at first boot.
  - cloudbase-init (pinned and hash-checked) only reads the config drive / NoCloud sources.
  - A KubeVirt sysprep disk is honored.
- **Checked before publishing.** A throwaway clone of the new disk must boot and run
  cloudbase-init user data (read back through the guest agent) before the boot source changes.
- **Dated builds.** Each build is stored as `<boot source>-<YYYY-MM>` (the newest `KEEP_BUILDS`,
  default 2, are kept for rollback) and then cloned to `<boot source>`, the PVC the DataSource
  serves.

Cluster and environment differences are kept out of the base:

- **Storage**: DataVolumes use `spec.storage` without `accessModes`/`volumeMode`, so each
  cluster's StorageProfile decides (RWX Block on ODF, RWO on LVMS).
- **virtio-win**: `install.sh` reads the image from ConfigMap `openshift-cnv/virtio-win`, so it
  always matches the installed OpenShift Virtualization release. Server 2025 needs a release
  with `2k25` drivers.
- **ISO server**: each `winXX/base` names its ISO file under a placeholder,
  `http://webserver.example.com/windows/<file>`. The environment's `ISO_BASE_URL` replaces
  `http://webserver.example.com` (Component `windows/environment`), so the ISOs must be at
  `<ISO_BASE_URL>/windows/<file>`.

The build runs in namespace `kubevirt-gitops` and takes 30-90 minutes or more (most of it Windows Update;
Server 2016 is the slowest). The Job exits at once if the boot-source PVC already exists.
Monthly patched images come from CronJob `windows-<OS>-rebuild`, which an environment turns on in
its settings; see [windows/build](windows/build/README.md).

Run one directly:

```
oc create namespace kubevirt-gitops
oc apply -k <config repo>/kubevirt-windows/default/overlays/win11    # or examples/environment/overlays/win11 with your ISO_BASE_URL
oc logs -f job/windows-11-install -n kubevirt-gitops
```

or via Argo CD with the ApplicationSet in the config repo (below). Sync is manual. The Job is a
`PostSync` hook, so it runs after every sync and is a no-op once the boot source exists.

Watch the install with `virtctl vnc windows-11-install -n kubevirt-gitops`.

## Checks

`hack/validate.sh` builds every kustomization, checks the Argo CD paths, renders the Windows build
templates for every version, and runs shellcheck. Run it before pushing. CI
(`.github/workflows/validate.yaml`) runs it too, plus yamllint, kubeconform and the PowerShell
checks (`hack/check-powershell.ps1`).

## Deploying from a config repo

This repository is generic: no environment's ISO server, overlays or Argo CD Applications live
here. Each environment keeps them in its own (usually private) config repository and uses this
one as a remote base, pinned to a tag:

```
<config repo>/kubevirt-windows/<environment>/
  kustomization.yaml          # oc apply -k: the ApplicationSet
  applicationset.yaml         # one Application per overlays/<version>, at a tag of the config repo
  settings/                   # Component: ConfigMap windows-environment-settings (ISO_BASE_URL),
                              # and the patch that turns on monthly rebuilds
  overlays/<version>/kustomization.yaml
```

Each overlay:

```
resources:
- https://github.com/therevoman/kubevirt-gitops//win11/base?ref=v1.0.0
components:
- ../../settings                                   # first: windows/environment reads its ConfigMap
- https://github.com/therevoman/kubevirt-gitops//windows/environment?ref=v1.0.0
```

[examples/environment](examples/environment) is a complete example with local paths; CI renders it.

Pin `?ref=` to a tag, never `main`. Argo CD caches manifests by the config repo's revision, so it
doesn't notice changes in a floating remote base until a hard refresh. To upgrade: tag this
repository, bump `?ref=` in the config repo, tag the config repo and point its ApplicationSet at
the new tag.

Moving a cluster from an ApplicationSet of this repository's former `clusters/<cluster>` or
`environments/<environment>` directories: delete it first, so two sets of Applications never
manage the same resources. It has `preserveResourcesOnDeletion`, and the Applications have no
`resources-finalizer`, so this keeps every build and boot source. Then apply the config repo's
ApplicationSet and sync its Applications; they adopt the existing resources:

```
oc delete applicationset snok-windows-boot-sources -n openshift-gitops
oc apply -k <config repo>/kubevirt-windows/default
```

History: the per-cluster branches (`sno`, `ocs`, `ocs-old`, `bm`, `win2k22`) were merged into
`main` on 2026-11-07 as per-cluster overlays (`clusters/<cluster>`, `winXX/overlays/<cluster>`).
Those clusters came to share every setting, and their overlays moved to a config repository.

Don't create a branch.
