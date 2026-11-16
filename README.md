# kubevirt-gitops

This repository is an example of managing KubeVirt virtual machines
and datavolumes using a GitOps workflow, specifically using ArgoCD
as provided by OpenShift GitOps.

Where possible, namespaces and resource names have been left variable
for portability, but since this is in support of an OpenShift blog,
the default leans to OpenShift products and namespaces.

## Get Started

On an OpenShift cluster with OpenShift Virtualization and OpenShift GitOps:

1. Add the Argo CD health checks for KubeVirt kinds to the GitOps operator's instance:
   `oc apply -k gitopsservice/health` (see [gitopsservice](gitopsservice/README.md)).
2. Create the cluster's app-of-apps: `oc apply -k clusters/<cluster>` (see
   [Microsoft Windows boot sources](#microsoft-windows-boot-sources)).

## Repository layout

| Path | What it is |
|---|---|
| [clusters](clusters) | Per-cluster app-of-apps (`oc apply -k clusters/<cluster>`): the only Argo CD entry point |
| [windows/build](windows/build) | Shared Windows boot-source build (Kustomize Component) |
| `win10`, `win11`, `win2k16`, `win2k19`, `win2k22`, `win2k25` | One Windows version each: build parameters + per-cluster overlays |
| [datavolumes](datavolumes) | Fedora and CentOS Stream cloud-image DataVolumes |
| [vms](vms) | Demo Fedora and CentOS VMs cloned from DataSources |
| [examples](examples) | VirtualMachinePool demos and a Windows example VM per version (not deployed by `clusters/`) |
| [gitopsservice](gitopsservice) | OpenShift GitOps settings: Argo CD health checks, infra placement, namespaces |
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
  windows-rebuild-cronjob.yaml  # monthly rebuild (suspended unless the cluster turns it on)
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
  overlays/
    openshift/                  # generic, no cluster specifics
    snok/ sno/ ocs/ bm/         # base + components: [clusters/<cluster>/windows]
```

`os.env` holds what differs between versions: the name key (`OS`), boot-source name, OS label,
desktop or server edition, virtio-win driver folder, image selector (`/IMAGE/NAME` for desktop,
`/IMAGE/INDEX` 2 for Server with Desktop Experience), generic product key, TPM, disk size and
Windows Update limits. To add a version, copy a `winXX/` directory, edit `os.env` and
`install-iso.yaml`; the ApplicationSets pick up its `overlays/<cluster>` directories.

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

Cluster differences are kept out of the base:

- **Storage**: DataVolumes use `spec.storage` without `accessModes`/`volumeMode`, so each
  cluster's StorageProfile decides (RWX Block on ODF, RWO on LVMS).
- **virtio-win**: `install.sh` reads the image from ConfigMap `openshift-cnv/virtio-win`, so it
  always matches the installed OpenShift Virtualization release. Server 2025 needs a release
  with `2k25` drivers.
- **ISO host**: each `winXX/base` names its ISO file (`http://qnas.revoweb.home/isos/...`).
  The host comes from `clusters/<cluster>/windows/settings.yaml` (`ISO_HOST`), which every
  `winXX/overlays/<cluster>` includes. Change a cluster's ISO server in that one file.

The build runs in namespace `kubevirt-gitops` and takes 30-90 minutes or more (most of it Windows Update;
Server 2016 is the slowest). The Job exits at once if the boot-source PVC already exists.
Monthly patched images come from CronJob `windows-<OS>-rebuild`, which a cluster turns on in
`clusters/<cluster>/windows/kustomization.yaml`; see [windows/build](windows/build/README.md).

Run one directly:

```
oc create namespace kubevirt-gitops
oc apply -k win11/overlays/snok
oc logs -f job/windows-11-install -n kubevirt-gitops
```

or with `make windows-boot-source WIN=win2k25` in `agent/snok`, or via Argo CD with the
per-cluster app-of-apps in [clusters](clusters). `oc apply -k clusters/snok` creates the
ApplicationSet `snok-windows-boot-sources`. It generates one `snok-<version>-boot-source`
Application for every `win*/overlays/snok` directory, tracking `main`. Sync is manual. The Job
is a `PostSync` hook, so it runs after every sync and is a no-op once the boot source exists.

Moving a cluster from the old per-version Applications to the ApplicationSet: delete the old
Applications first. They have no `resources-finalizer`, so this keeps every build and boot source.
The ApplicationSet then creates them again under the same names:

```
oc delete application -n openshift-gitops $(oc get application -n openshift-gitops -o name | grep -E '/snok-win[0-9k]+-boot-source$' | cut -d/ -f2)
oc apply -k clusters/snok
```

Watch the install with `virtctl vnc windows-11-install -n kubevirt-gitops`.

## Checks

`hack/validate.sh` builds every kustomization, checks the Argo CD paths, renders the Windows build
templates for every version, and runs shellcheck. Run it before pushing. CI
(`.github/workflows/validate.yaml`) runs it too, plus yamllint, kubeconform and the PowerShell
checks (`hack/check-powershell.ps1`).

## Clusters and branches

All per-cluster branches (`sno`, `ocs`, `ocs-old`, `bm`, `win2k22`) were merged into `main` on
2026-11-07. Cluster differences now live in `overlays/<cluster>` directories, and
`clusters/<cluster>` holds that cluster's ApplicationSet and Windows settings. To add a cluster:
- copy a `clusters/<name>` directory and change the name and `ISO_HOST`
- add `winXX/overlays/<name>` for each Windows version

Don't create a branch.
