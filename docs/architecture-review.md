# Architecture review and improvement tracker

Review date: 2026-11-16. Update the checkboxes and status lines as work lands.

Legend: `[x]` done, `[~]` partly done (see note), `[ ]` open.

## Summary

The Windows boot-source builds are the core of this repository. They are well engineered, but they
started as hand-maintained copies that drifted: about 10 build fixes went into `win11` only. The
rest of the repository carried 2022-era upstream scaffolding that no longer matched how it is
deployed.

The plan, in order:

1. Fix broken or risky items (P0).
2. Restructure the Windows builds around one shared build component.
3. Add the missing Windows versions on that component.
4. Replace per-cluster Applications with an ApplicationSet, and add CI.

## Step 1: P0 fixes (broken or risky)

- [x] **1.1 `vms/` did not build.** `vms/base/fedora.yaml` and `centos.yaml` were raw `kind: List`
  dumps. `centos.yaml` was a copy of the Fedora VM, so both defined `fedora-gitops1`. `running:`
  was mis-indented outside `spec`. An older duplicate `vms/centos.yaml` sat at the root.
  Fix: plain VirtualMachine manifests with `runStrategy`, the duplicate removed, and the
  upstream-Kubernetes overlay dropped.
- [x] **1.2 Two competing entry points.** `apps/*.yaml` (auto-sync from `HEAD`) deployed a 2022
  upstream stack: KubeVirt v0.49, CDI v1.43, cert-manager v1.6 and HPP, plus a CNV subscription
  pinned to `v4.10`. `clusters/<cluster>` (manual sync from `main`) is how the repository is used
  today. Removed: `apps/`, `kubevirt/`, `cdi/`, `hpp/`, `cert-manager/`, and the `kubernetes`
  overlays of `vms/` and `datavolumes/`. `clusters/` is now the only Argo CD entry point.
- [~] **1.3 Credentials in git.**
  - [x] win2k19/win2k22 hard-coded the Administrator password `R3dh4t1!`. They now use the
    shared build (step 2), which sets a random password for each build and never stores it.
  - [x] `vms/` carried plaintext passwords and an SSH key that belongs to nobody on this
    project (from upstream). Now an SSH public key comes from a Secret you create
    (`accessCredentials`), and there are no passwords.
  - [ ] `examples/` (pool demos) keep their demo passwords (`redhat`, `EXAMPLE`) and a lab SSH
    key. They are labeled demo-only in `examples/README.md`. Open: move them to generated
    Secrets if the demos are ever used outside the lab.
- [x] **1.4 Leftovers.**
  - Moved the five pool demos to `examples/`: `pool-of-vms`, `pool-of-fedoras`, `vmpools`,
    `virtualmachinepool`, `win2k19virtualmachinepool`.
  - Deleted the broken `test.sh`, and the `servicemesh/` (2022) and `acm/` directories.
- [ ] **1.5 `virtualization/`** still holds the 2022 OLM install of OpenShift Virtualization
  (`startingCSV: v4.10`). Nothing references it anymore: clusters install OpenShift
  Virtualization from the snok post-install GitOps. Decide whether to delete it or refresh it.
  Its `namespaces.yaml` (`kubevirt-gitops` with the `managed-by` label) may be worth keeping.

## Step 2: shared Windows build

- [x] **2.1 One build, many OS versions.** Shared files live in `windows/build/`, a Kustomize
  Component: ServiceAccount, RBAC, Job, `install.sh`, `post-install.ps1`, the build VM, the
  clone DataVolume and `autounattend.xml`. Each `winXX/base/` is now three small files:
  `kustomization.yaml`, `os.env` (what differs between versions) and `install-iso.yaml`.
- [x] **2.2 Server builds use the win11 machinery**, so all versions get the same features:
  - fail fast, with status read through the guest agent
  - a random build password
  - a pinned, hash-checked cloudbase-init
  - Windows Update in rounds, with stuck-update detection
  - a WinRE partition before C:, so clones can grow C:
  - removal of user-only Appx packages
  - a sysprep failure check
  - SetupComplete hooks, including honoring a KubeVirt sysprep disk
- [x] **2.3 External contract kept.** The paths `winXX/overlays/<cluster>`, the Job and VM names
  `windows-<ver>-install` and the boot-source PVC/DataSource names didn't change, so
  `agent/snok/Makefile` (`make windows-boot-source WIN=...`) works as before.
- [x] **2.5 virtio NIC for every version.** The build VM uses `model: virtio` instead of e1000e.
  Windows has no inbox virtio NIC driver, so the guest is offline until post-install installs
  virtio-win (NetKVM). Post-install then waits up to 5 minutes for DNS before the first download,
  and the driver-store check before sysprep also requires `netkvm.inf`. The win2k19 pool example
  uses virtio too.
- [ ] **2.4 Verify on a cluster.** Checked offline on 2026-11-16:
  - `oc kustomize` builds every overlay of all six versions.
  - The rendered resource names match the old ones; the params ConfigMap is the only addition.
  - `install.sh` rendering was run for every `os.env`; the output parses as XML/YAML, with no
    placeholders left.
  - For win11, the rendered answer file and build VM are identical to the previous win11 files,
    apart from comments and the scripts-CD volume name.
  - `bash -n` and `shellcheck` pass on `install.sh`.

  Not yet checked:
  - `post-install.ps1` hasn't been parse-checked (no PowerShell available here).
  - win2k19 and win2k22 haven't been built on the new build yet. Rebuild them once and record the
    result here.

## Step 3: new Windows versions

- [x] **3.1** `win10`: Windows 10 Pro, desktop, no TPM.
- [x] **3.2** `win2k16`: Windows Server 2016 Standard (Desktop Experience). Windows Update stall
  limit raised, because 2016 cumulative updates are slow.
- [~] **3.3** `win2k25`: Windows Server 2025 Standard (Desktop Experience). Needs a virtio-win
  release with `2k25` drivers (the build fails fast if `viostor`/`vioscsi` are missing).
  **Blocked:** no Server 2025 ISO exists yet. Upload it as `isos/windows/server-2025.iso` to
  `qnas.revoweb.home` and to `192.168.20.14` (ocs).
- [x] **3.4** Applications for all three in every `clusters/<cluster>`.
- [ ] **3.5 Confirm against a cluster:**
  - [x] ISO names. On both `qnas.revoweb.home` and `192.168.20.14`:
    `Windows10-22H2.iso` and `windows/server-2016.iso` exist; `windows/server-2025.iso` is
    missing (see 3.3). Expect the 2016 file to be an evaluation ISO (index 2 = Standard Desktop
    Experience).
  - The template disk sizes (`DISK_SIZE`; a clone source must not be larger than what the
    templates request):
    `oc get template -n openshift -o name | grep -E 'windows(10|2k16|2k25)'`
  - That the DataSources `win10`, `win2k16` and `win2k25` exist in
    `openshift-virtualization-os-images`.
- [ ] **3.6 Build each new version once** and record the result here.

## Step 4: delivery and quality (open)

- [ ] **4.1 ApplicationSet.** A matrix of clusters × Windows versions replaces the 4 × 6
  near-identical Applications in `clusters/*/applications.yaml`. 12 of the 15 overlays per OS
  are an empty `resources: ../../base`; only the ISO host differs, on `ocs`.
- [ ] **4.2 ISO host per cluster.** Move `qnas.revoweb.home` out of the bases into per-cluster
  config (one `ISO_BASE_URL`) and keep only the file name per OS.
- [ ] **4.3 CI (GitHub Actions):**
  - `kustomize build` for every directory except `windows/build`, which is a Component and only
    builds through a `winXX/base`
  - `kubeconform` with KubeVirt/CDI/Argo CD schemas
  - `yamllint`
  - `shellcheck windows/build/config/install.sh`
  - PSScriptAnalyzer on `post-install.ps1`
  - a check that every Application `path:` exists
- [ ] **4.4 Pin images.** The build Job uses `ose-cli-rhel9:latest`; the virtio-win fallback tag
  is fixed at `v4.22`.
- [ ] **4.5** Outside this repository: `/opt/ocp4/bin/kustomize/kustomize` is a broken symlink
  (it points at `kustomiz`). Use `oc kustomize` until it is fixed.

## Enhancements (open)

- [ ] **E1 Check a build before publishing it.** Boot a throwaway clone of the new disk, wait for
  the guest agent and cloudbase-init, and only then point the DataSource at it. This keeps a
  bad sysprep away from the templates.
- [ ] **E2 Monthly patched images.** Build into dated PVCs (`win11-2026-12`) and switch the
  DataSource when E1 passes, via a CronJob or a scheduled sync. Today a boot source is never
  rebuilt once its PVC exists.
- [ ] **E3 Argo CD health.** Move the Lua health checks in `setup/` into the GitOps operator
  config, so DataVolumes, VMs and build Jobs report real health.
- [ ] **E4 Example VMs per Windows version.** Clone the DataSource with a sysprep or
  cloudbase-init volume, to show each image working end to end.
- [x] **E5 Per-directory READMEs** for `windows/build` (parameters, how to add a version),
  `examples/` and `vms/`.
