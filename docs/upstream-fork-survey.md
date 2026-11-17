# Upstream and fork survey

Survey date: 2026-11-16. Outcome: nothing merged.

## Lineage

| Repository | Role | State |
|---|---|---|
| [cwilkers/kubevirt-gitops](https://github.com/cwilkers/kubevirt-gitops) | Source of the network | Last commit 2023-05-08 (`395d1e2` "Add DV garbage-collection protection") |
| [RHsyseng/kubevirt-gitops](https://github.com/RHsyseng/kubevirt-gitops) | Direct parent of this fork | No commits beyond cwilkers |
| [therevoman/kubevirt-gitops](https://github.com/therevoman/kubevirt-gitops) | This repo | About 206 commits ahead of upstream |

This fork is now the most current copy in the network. The local clone has an `upstream` remote that points at cwilkers.

## Upstream branches

| Branch | Content | Verdict |
|---|---|---|
| `main` | Nothing newer than this fork's base | — |
| `windows-only` | Windows-only Argo app | Already merged (`apps/windows.yaml`, `apps/{base,overlays}/windows`) |
| `cloudynit` | 2022 debugging of cloudbase-init and sysprep for win2k19 | Superseded by the current win2k19 rewrite |
| `isotest` | Plain sysprep; `volumeMode: Block` on the install disk | Superseded; the StorageProfile now picks the volume mode |
| `gitopscon22` | `modernization/` bookinfo-legacy VM demo (VM, DataVolume, Service) | Ignored: not wanted in this fork. Skip it in future surveys |

## GitHub forks

All 45 forks were checked: forks of cwilkers, RHsyseng, tosin2013 and berenss.

| Group | Forks | Verdict |
|---|---|---|
| Workshop edits to the demo VMs | SherinV, berenss, juliusgun, jalvarez-rh, ipilcher, levenhagen, awez-sonde, Carlos-ZRM, fmoctezuma, sahu-apoorva, johanodell, cmcornejocrespo, rhodain | Nothing reusable |
| Their own restructures | tosin2013, jkeam, dharmesh-b (`components/` layout, ODF, httpd server); justone0127 (its own templates) | Different project shape |
| aqilbeig | win2k19 port to plain upstream KubeVirt (`kubevirt-os-images`, `bitnami/kubectl`, community virtio image) | Hard-codes non-OpenShift choices |
| knorr3 | `install.sh` waits for VM `Stopped` instead of VMI `Succeeded` | Already covered: `install.sh` treats a missing VMI as finished |
| serhat-dirik, aqilbeig, giofontana | win2k19 ISO points at a public Microsoft eval link or a lab IP | The base already uses NAS URLs, and overlays can patch them |

## Local clones

These clones were checked: `/opt/ocp4/{hosted/bm,hosted/ocs,agent/sno,agent/snoq,agent/ocs,agent/snok}/postinstall/kubevirt-gitops*`.

- None of them has unpushed commits.
- Their `origin` branches (`bm`, `ocs`, `ocs-old`, `sno`, `win2k22`) are fully merged into `main`.
- Two uncommitted edits are already in `main`: `sockets: 4` and the `pool-of-fedoras` namespace fix.
- The rest are leftovers from the old `win2k19/config/` layout.
- `agent/ocs/postinstall/kubevirt-gitops` holds staged but uncommitted win2k22 autounattend and install-script work in the old layout. `main`'s `win2k22/base` has been rewritten since. Review it before cleaning that clone.

## Next time

Only check commits pushed after 2026-11-16. A full re-survey isn't needed. To list forks with their last push date:

```sh
gh api --paginate 'repos/RHsyseng/kubevirt-gitops/forks?per_page=100' \
  --jq '.[] | "\(.pushed_at)\t\(.full_name)"' | sort -r
```
