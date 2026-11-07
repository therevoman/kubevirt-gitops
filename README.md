# kubevirt-gitops

This repository is an example of managing KubeVirt virtual machines
and datavolumes using a GitOps workflow, specifically using ArgoCD
as provided by OpenShift GitOps.

Where possible, namespaces and resource names have been left variable
for portability, but since this is in support of an OpenShift blog,
the default leans to OpenShift products and namespaces.

## Get Started

Under the [setup](setup) directory, there are a number of scripts to
help in an OpenShift GitOps deployment.

To run everything, use [`install.sh`](setup/install.sh) without any arguments.
This script will:

  - Discover the ArgoCD namespace and configuration CR names.
  - Install health check scripts that ArgoCD uses to better track status of custom resources.

More in-depth descriptions may be found in the [README](setup/)

## Application Directories

Other directories in this repository are designed to support Applications in ArgoCD. Each of these directories
contains a [kustomization.yaml](https://kubectl.docs.kubernetes.io/references/kustomize/glossary/#kustomization)
and an [application.yaml](https://argo-cd.readthedocs.io/en/stable/getting_started/#6-create-an-application-from-a-git-repository).

### KubeVirt

Under the [kubevirt](kubevirt) directory is an ArgoCD application and manifests
to install KubeVirt on a Kubernetes cluster.

### OpenShift Virtualization

Under [virtualization](virtualization) are manifests to create an OpenShift
Virtualization installation using the OpenShift Operator Lifecycle Manager
(OLM).

### DataVolumes

The [datavolumes](datavolumes) directory contains DataVolume manifests which
will download specific cloud images of Fedora and CentOS 8 Stream for use as
boot sources for OpenShift Virtualization's included OS templates.

### Virtual Machines

The [vms](vms) directory works with the DataVolumes provided in
[datavolumes](datavolumes) to create a Fedora and CentOS VM.

### Microsoft Windows boot sources (win2k19, win2k22, win11)

[win2k19](win2k19), [win2k22](win2k22) and [win11](win11) each build the boot-source PVC
(`openshift-virtualization-os-images/win2k19`, `win2k22`, `win11`) that the matching
`windows2k19-*`, `windows2k22-*` and `windows11-*` OpenShift Virtualization templates clone.

Each app is a Kustomize `base/` plus `overlays/<cluster>`:

```
winXX/
  base/                         # everything, cluster-agnostic
    install-iso.yaml            # DataVolume importing the install ISO over HTTP
    windows-install-{sa,rbac,job}.yaml
    config/                     # -> ConfigMap windows-XX-install-scripts (configMapGenerator)
      install.sh                #    Job: create VM, start it, wait for sysprep shutdown, clone to boot source
      windows-install-vm.yaml   #    build VM (TPM/SecureBoot for win11)
      clone-boot-source.yaml    #    DataVolume into openshift-virtualization-os-images
      autounattend.xml          #    unattended install (also mounted into the VM as a CD-ROM)
      post-install.ps1          #    virtio drivers, guest agent, cloudbase-init, sysprep /generalize
  overlays/
    openshift/                  # generic, no cluster specifics
    snok/ sno/ ocs/ bm/         # per-cluster patches (today: ISO URL on ocs)
```

Cluster differences are kept out of the base:

- **Storage**: DataVolumes use `spec.storage` without `accessModes`/`volumeMode`, so each
  cluster's StorageProfile decides (RWX Block on ODF, RWO on LVMS).
- **virtio-win**: `install.sh` reads the image from ConfigMap `openshift-cnv/virtio-win`, so it
  always matches the installed OpenShift Virtualization release.
- **Drive letters**: `autounattend.xml` and `post-install.ps1` find the scripts and virtio-win
  CDs by their contents.
- **ISO URL**: defaults to `http://qnas.revoweb.home/isos/...`; an overlay patches it (see
  `overlays/ocs`).

The build runs in namespace `kubevirt-gitops` and takes 30-90 minutes. `install.sh` exits at
once if the boot-source PVC already exists; delete that PVC to rebuild.

Run one directly:

```
oc create namespace kubevirt-gitops
oc apply -k win11/overlays/snok
oc logs -f job/windows-11-install -n kubevirt-gitops
```

or via Argo CD with the per-cluster app-of-apps in [clusters](clusters):
`oc apply -k clusters/snok` creates `snok-win2k19-boot-source`, `snok-win2k22-boot-source` and
`snok-win11-boot-source` Applications that track `main`. Sync is manual. The Job is a
`PostSync` hook, so it runs after every sync and is a no-op once the boot source exists.

Watch the install with `virtctl vnc windows-11-install -n kubevirt-gitops`. The build account
is `Administrator` / `R3dh4t1!`; sysprep generalizes the image, and clones get their own
identity from cloud-init/cloudbase-init or the template.

## Clusters and branches

All per-cluster branches (`sno`, `ocs`, `ocs-old`, `bm`, `win2k22`) were merged into `main` on
2026-11-07. Cluster differences now live in `overlays/<cluster>` directories, and
`clusters/<cluster>` holds that cluster's Applications. Add a cluster by adding an overlay to
each app and a `clusters/<name>` directory; don't create a branch.
