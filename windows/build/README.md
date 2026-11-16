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

## Templates

`install.sh` renders `windows-install-vm.yaml`, `clone-boot-source.yaml` and `autounattend.xml`.
It replaces each at-sign placeholder with the parameter of that name and keeps or drops the lines
between `IF_<BLOCK>`/`END_<BLOCK>` markers (`TPM`, `DESKTOP`, `PRODUCT_KEY`). Rendering fails if
any placeholder is left. Don't write a marker name inside an ordinary comment: `install.sh` would
treat it as a block boundary.

`post-install.ps1` runs in the guest from the scripts CD. It reads `build-params.ps1`, which
`install.sh` writes next to it: `$DriverDir`, `$Edition`, `$WuMaxRounds`.
