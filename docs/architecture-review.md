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

- [x] **4.1 ApplicationSet.** `clusters/base/windows-boot-sources.yaml` is an ApplicationSet
  with a matrix generator: the cluster (set per cluster with one patch) × a git directory
  generator over `win*/overlays/<cluster>`. It replaces the 24 hand-written Applications, and a
  new Windows version needs no Application edit.
  - Generated names are the same as before (`<cluster>-<version>-boot-source`), checked for all
    4 clusters.
  - `preserveResourcesOnDeletion: true` keeps boot sources if the ApplicationSet or a version
    is removed.
  - Migration: delete a cluster's old Applications before applying (README, "Run one directly").
  - [ ] Not yet checked on a live Argo CD. It needs goTemplate and matrix-parameter support
    (Argo CD 2.5+).
- [x] **4.2 ISO host per cluster.** `clusters/<cluster>/windows/` is a Component with one
  setting, `ISO_HOST`. It replaces the host part of every install ISO URL; the path stays in
  `winXX/base`. The settings ConfigMap is `local-config`, so it isn't applied. All per-cluster
  overlays are now the same 6 lines (base + that Component), and the ocs URL patches are gone.
  Output is byte-identical to `refactor` for all 30 overlays.
- [x] **4.3 CI** (`.github/workflows/validate.yaml`, on every push and pull request):
  - `hack/validate.sh` (also runs locally):
    - builds every kustomization except Components
    - checks every Application `path:` and every ApplicationSet directory pattern
    - renders the Windows templates for each `os.env` (shared `check_params` validation, XML/YAML
      parse, no placeholders left)
    - runs `shellcheck`
  - `yamllint` (`.yamllint.yaml`: real errors only; the templates are checked after rendering)
  - `kubeconform` against the Kubernetes schemas and the datreeio CRD catalog (KubeVirt, CDI,
    Argo CD)
  - `hack/check-powershell.ps1`: parses `post-install.ps1` and each script embedded in it as a
    here-string, then runs PSScriptAnalyzer at Error severity

  Locally checked: `hack/validate.sh` passes. It fails as it should on a missing parameter, a bad
  `EDITION` and a leftover placeholder. yamllint is clean.
  - [ ] Not yet run: the kubeconform and PowerShell steps (neither tool is available on this
    host). The first CI run will show whether they need tuning.
- [x] **4.4 Pin images.** The build Job uses `ose-cli-rhel9:v4.22` instead of `:latest`; v4.22 was
  the newest minor tag in the Red Hat catalog on 2026-11-16. The virtio-win fallback in
  `install.sh` is pinned to the same minor; comments say to bump both together. Normally the
  virtio-win image comes from the cluster (`openshift-cnv/virtio-win`).
- [x] **4.5 Local kustomize (outside this repository).** Correction to the review: the symlink is
  fine. The review misread truncated `ls` output. The binary is
  `/opt/ocp4/bin/kustomize/kustomize` (v5.8.3). `/opt/ocp4/bin/kustomize` is a directory, so
  `kustomize` through `PATH=/opt/ocp4/bin` fails with "permission denied". Nothing changed in
  `bin/`. To use it, add `/opt/ocp4/bin/kustomize` to `PATH`, or run
  `KUSTOMIZE="/opt/ocp4/bin/kustomize/kustomize build" hack/validate.sh` (passes; checked
  2026-11-16).

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
