# Shared Windows boot-source build

A Kustomize Component that every `winXX/base` includes. It holds everything about building a
Windows boot source; a version only supplies parameters.

## How a version plugs in

`winXX/base/kustomization.yaml` adds two things next to this Component:

- `install-iso.yaml`: the ISO DataVolume `<BOOT_SOURCE>-install-iso`
- ConfigMap `windows-OS-install-params`, generated from `os.env`

The Component's `replacements` copy `data.OS` (`11`, `2k22`, ...) into every resource name. So
`windows-OS-install` becomes the Job, VM, ServiceAccount, RBAC and ConfigMaps
`windows-11-install*`, and each version can build in the same namespace. The Job reads the params
ConfigMap through `envFrom`.

## Parameters (`os.env`)

| Key | Example | Used for |
|---|---|---|
| `OS` | `2k25` | Resource names (`windows-2k25-install`); must match `agent/snok/Makefile` (`WIN=win2k25`) |
| `BOOT_SOURCE` | `win2k25` | Boot-source PVC/DataSource and ISO DataVolume name |
| `OS_ID` | `windows2k25` | `vm.kubevirt.io/os` on the build VM |
| `OS_NAME` | `Microsoft Windows Server 2025` | Display name |
| `WORKLOAD` | `server` | `vm.kubevirt.io/workload` |
| `EDITION` | `desktop` / `server` | Desktop-only answer-file and post-install steps |
| `DRIVER_DIR` | `2k25` | virtio-win folder (`w10`, `w11`, `2k16`, `2k19`, `2k22`, `2k25`) |
| `IMAGE_KEY`, `IMAGE_VALUE` | `/IMAGE/INDEX`, `2` | Which image in `install.wim` Setup installs |
| `PRODUCT_KEY` | (empty) | Generic install key; the block is dropped when empty |
| `TPM` | `false` | Adds a TPM to the build VM (Windows 11) |
| `DISK_SIZE` | `60Gi` | Build disk and boot-source size; must not exceed what the templates request |
| `STALL_MIN` | `150` | Fail when the build status doesn't change for this long |
| `WU_MAX_ROUNDS` | `8` | Windows Update rounds before the build gives up |
| `AGENT_TIMEOUT_MIN` | `60` (default) | VM start to first status from the guest |
| `VERIFY` | `true` (default) | Check the image on a throwaway clone before publishing it (see below) |
| `VERIFY_TIMEOUT_MIN` | `30` (default) | Time the check clone has to boot and run cloudbase-init |
| `REBUILD_SCHEDULE` | `0 1 20 * *` | Cron schedule (UTC) of the monthly rebuild; one day per version, after Patch Tuesday |
| `KEEP_BUILDS` | `2` (default) | Dated builds kept in `openshift-virtualization-os-images` |

## Image check before publishing

After sysprep shuts the build VM down, `install.sh` boots `windows-<OS>-verify`, a throwaway
clone of the new disk (`windows-verify-vm.yaml`), the way a template clone boots. Its cloud-init
volume carries user data that writes a random token to `C:\Windows\Temp\image-check.txt`; the
check passes when the guest agent returns that token. That proves specialize, OOBE, SetupComplete,
the guest agent and cloudbase-init all work. Only then is the disk cloned to the boot source.

On a failure the Job exits non-zero and prints the tail of the cloudbase-init log. The check VM
is left for debugging, and the boot source is not touched. The next build replaces the check VM.

## Builds, monthly rebuilds and rollback

Every build ends the same way:

1. The image check above passes.
2. The disk is cloned to `<BOOT_SOURCE>-<YYYY-MM>` in `openshift-virtualization-os-images`,
   labelled `kubevirt-gitops/boot-source=<BOOT_SOURCE>`. The build VM is deleted.
3. That build is cloned to `<BOOT_SOURCE>`, the PVC the DataSource points at. A previous
   `<BOOT_SOURCE>` is deleted first, so new VMs from the templates wait until the clone finishes
   (minutes with CSI clones). Running VMs have their own disks and are not affected. The
   DataSource itself is never edited: SSP owns it.
4. Dated builds past the newest `KEEP_BUILDS` are deleted.

Two things start a build:

- **Job `windows-<OS>-install`** (Argo CD PostSync hook, or `oc apply -k`): the first build. It
  exits at once if `<BOOT_SOURCE>` exists.
- **CronJob `windows-<OS>-rebuild`**: a fresh build with that month's updates, on
  `REBUILD_SCHEDULE`. It runs the Job's pod template (copied by the Component's replacements)
  and exits at once if this month's build exists. It is **suspended by default**. Turn it on
  for a cluster with the commented patch in `clusters/<cluster>/windows/kustomization.yaml`.
  To run one now:
  `oc create job --from=cronjob/windows-11-rebuild windows-11-rebuild-now -n kubevirt-gitops`
  (the Job name must contain `-rebuild-`).

Both refuse to start while the build VM `windows-<OS>-install` exists, that is while a build
runs, or after a failed one was left for debugging.

### Roll back

List the builds, then publish an older one under the boot-source name:

```
oc get pvc -n openshift-virtualization-os-images -l kubevirt-gitops/boot-source=win11
oc delete dv,pvc win11 -n openshift-virtualization-os-images --ignore-not-found
cat <<'EOF' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: win11
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc: {namespace: openshift-virtualization-os-images, name: win11-2026-11}
  storage:
    resources:
      requests:
        storage: 64Gi
EOF
```

The next monthly rebuild publishes a new build again; suspend the CronJob to stay on the old one.

## Templates

`install.sh` renders `windows-install-vm.yaml`, `windows-verify-vm.yaml`, `clone-boot-source.yaml`
and `autounattend.xml`.
It replaces each at-sign placeholder with the parameter of that name and keeps or drops the lines
between `IF_<BLOCK>`/`END_<BLOCK>` markers (`TPM`, `DESKTOP`, `PRODUCT_KEY`). Rendering fails if
any placeholder is left. Don't write a marker name inside an ordinary comment: `install.sh` would
treat it as a block boundary.

`post-install.ps1` runs in the guest from the scripts CD. It reads `build-params.ps1`, which
`install.sh` writes next to it: `$DriverDir`, `$Edition`, `$WuMaxRounds`.
