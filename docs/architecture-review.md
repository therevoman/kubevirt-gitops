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
- [x] **1.3 Credentials in git.**
  - [x] win2k19/win2k22 hard-coded the Administrator password `R3dh4t1!`. They now use the
    shared build (step 2), which sets a random password for each build and never stores it.
  - [x] `vms/` carried plaintext passwords and an SSH key that belongs to nobody on this
    project (from upstream). Now an SSH public key comes from a Secret you create
    (`accessCredentials`), and there are no passwords.
  - `examples/` (pool demos) keep their demo passwords (`redhat`, `EXAMPLE`) and a lab SSH
    key, by decision (2026-11-16). They are labeled demo-only in `examples/README.md`.
- [x] **1.4 Leftovers.**
  - Moved the five pool demos to `examples/`: `pool-of-vms`, `pool-of-fedoras`, `vmpools`,
    `virtualmachinepool`, `win2k19virtualmachinepool`.
  - Deleted the broken `test.sh`, and the `servicemesh/` (2022) and `acm/` directories.
- [x] **1.5 `virtualization/` removed.** It held the 2022 OLM install of OpenShift
  Virtualization (`startingCSV: v4.10`) and nothing referenced it: clusters install OpenShift
  Virtualization from the snok post-install GitOps. Its namespaces (`kubevirt-gitops`,
  `openshift-cnv`, `openshift-virtualization-os-images` with the `managed-by` label) are also in
  `gitopsservice/`.

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

  On the snok cluster on 2026-11-16 (OpenShift 5.0.1, OpenShift Virtualization 5.0.0):
  - Every overlay of all six versions passes a server-side dry run. win11, win2k19 and win2k22
    show their existing resources as `unchanged`.
  - win10 built end to end on the shared build (3.6). Two fixes came out of it:
    - Multi-architecture ISOs (Windows 10 Media Creation Tool) stop at a Windows Boot Manager
      menu that has no timeout. `install.sh` now presses Enter when the ISO reads stall.
    - On Windows 10, removing the per-user Cortana package at first logon fails with
      0x80070002. `post-install.ps1` now logs failed Appx removals as warnings.
  - The virtio NIC works: NetKVM installed, network up, `netkvm.inf` in the driver store.
  - win2k22 rebuilt on the new build (2026-11-17, Job from `cronjob/windows-2k22-rebuild`) in
    52 min. It took 3 Windows Update rounds, and the image check passed in 1 min. It replaced the
    existing `win2k22` boot source (see E2). A `windows2k22-server-medium` clone booted Server 2022
    Standard Evaluation, build 20348.
  - win2k16 (3.6) brought a third fix. On Server 2016 (PowerShell 5.1.14393),
    `Install-Module PSWindowsUpdate` ends the running transcript, so the next `Stop-Transcript`
    threw and stopped post-install before the first reboot. `post-install.ps1` now tolerates a
    transcript that has already ended, and restarts it after the module loads.
  - Every build fired `GuestFilesystemAlmostOutOfSpace` (critical) for the install ISO (`D:\`,
    100% used). KubeVirt's rule excludes `udf` but Windows reports `UDF`. `install.sh` now ejects
    the ISO when Setup has finished (`virsh change-media --eject --live`). Checked by hand on the
    running win2k25 build: the drive is gone from the guest's filesystem metrics.

  Not yet checked:
  - win2k19 hasn't been rebuilt on the new build. Its boot source exists on snok; a rebuild
    replaces it the same way as win2k22.

## Step 3: new Windows versions

- [x] **3.1** `win10`: Windows 10 Pro, desktop, no TPM.
- [x] **3.2** `win2k16`: Windows Server 2016 Standard (Desktop Experience). Windows Update stall
  limit raised, because 2016 cumulative updates are slow.
- [x] **3.3** `win2k25`: Windows Server 2025 Standard (Desktop Experience). Needs a virtio-win
  release with `2k25` drivers (the build fails fast if `viostor`/`vioscsi` are missing).
  The ISO (`isos/windows/server-2025.iso` on `qnas.revoweb.home` and `192.168.20.14`) was first
  a copy of the Windows 11 ISO; Setup showed the Windows 11 product-key page. The real Server
  2025 ISO (volume label `SSS_X64FREE_EN-US_DV9`) was uploaded on 2026-11-17 and builds (3.6).
- [x] **3.4** Applications for all three in every `clusters/<cluster>`.
- [x] **3.5 Confirm against a cluster** (snok, 2026-11-16):
  - [x] ISO names. On both `qnas.revoweb.home` and `192.168.20.14`:
    `Windows10-22H2.iso`, `windows/server-2016.iso` and `windows/server-2025.iso` exist
    (see 3.3). Expect the 2016 file to be an evaluation ISO (index 2 = Standard Desktop
    Experience).
  - [x] Template disk sizes. The templates request 60Gi for windows10 and windows2k16, 64Gi for
    windows11 and windows2k25. `DISK_SIZE` is not larger in any version (win2k25 is 60Gi).
  - [x] The DataSources for all six versions exist in `openshift-virtualization-os-images`.
  - Templates come in two variants: `*-medium` boots from SATA, `*-highperformance-*` from virtio.
    The win10 image boots on both (see 3.6).
- [x] **3.6 Build each new version once.**
  - [x] win10, on snok on 2026-11-16, in 41 min. Steps: Setup, post-install, 2 Windows Update
    rounds, sysprep, E1 check (2 min), then `win10-2026-11` was published as `win10`. Clones
    boot and run cloudbase-init from the `windows10-highperformance-medium` template (virtio
    disk) and from `examples/windows/win10` (SATA). That template asks for dedicated CPUs, which
    snok doesn't have, so the test removed them.
  - [x] win2k16, on snok on 2026-11-17, in 100 min (4 Windows Update rounds, image check 1 min).
    It needed the transcript fix (2.4). A `windows2k16-server-medium` clone booted Server 2016,
    build 14393, with the guest agent up in 45 s.
  - [x] win2k25, on snok on 2026-11-17, in 56 min (4 Windows Update rounds, image check 1 min).
    A `windows2k25-server-medium` clone booted Windows Server 2025 Standard Evaluation, build
    26100, with the guest agent up in 60 s.

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
  - [x] Synced through Argo CD on snok on 2026-11-17: all six Applications Synced and Healthy,
    and each build Job (PostSync hook) exited because its boot source exists. Two things had to
    be fixed first, both now in the README and `gitopsservice/README.md`:
    - The `openshift-gitops` instance can only write to namespaces labelled
      `argocd.argoproj.io/managed-by=openshift-gitops`. Without the label on `kubevirt-gitops`
      and `openshift-virtualization-os-images`, syncs stayed `Running` with nothing applied.
    - The application controller's default 2Gi limit was OOMKilled on snok (about 640 CRDs);
      it uses about 2.3Gi after the syncs. `gitopsservice/health` now sets a 6Gi limit.
  - Removed the unused `win*/overlays/openshift` (no cluster's ApplicationSet picks them up) and
    the orphaned `datavolumes/overlays/openshift/application.yaml` left from the old `apps/`
    entry point.
  - [ ] Not yet checked on a live Argo CD. It needs goTemplate and matrix-parameter support
    (Argo CD 2.5+).
- [x] **4.2 ISO host per cluster.** `clusters/<cluster>/windows/` is a Component with one
  setting, `ISO_HOST`. It replaces the host part of every install ISO URL; the path stays in
  `winXX/base`. The settings ConfigMap is `local-config`, so it isn't applied. All per-cluster
  overlays are now the same 6 lines (base + that Component), and the ocs URL patches are gone.
  Output is byte-identical to `refactor` for all 30 overlays.
- [x] **4.4 Environments in a config repository** (2026-11-17). The four clusters had come to
  share every setting (ocs now uses the same ISO host). Settings are needed per environment, not
  per cluster, and they don't belong in this public, generic repository:
  - `clusters/` and every `winXX/overlays/` are gone. Environments keep their overlays, settings
    and ApplicationSet in a config repository (for snok: `openshift-works-gitops`, branch
    `new-customizations`, `kubevirt-windows/default/`). They use `winXX/base` and
    `windows/environment` as remote bases pinned to a tag of this repository.
  - The install ISO URLs in `winXX/base` use the placeholder
    `http://webserver.example.com/windows/<file>`. The environment's `ISO_BASE_URL` (replacing
    `ISO_HOST`) replaces everything before `/windows/` (Component `windows/environment`), so an
    environment sets the server and a path prefix.
  - All ISOs live under `/isos/windows/`. win10 and win11 now use `win-10-22h2.iso` and
    `win-11-25h2.iso` there, instead of `Windows10-22H2.iso` and `Win11_25H2_English_x64.iso` at
    the top of `/isos/`.
  - `examples/environment` is a complete environment with local paths. `hack/validate.sh` checks
    that it has an overlay for every version and that every ISO URL uses its `ISO_BASE_URL`.
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

## Enhancements

- [x] **E1 Check a build before publishing it.** After sysprep, `install.sh` boots
  `windows-<OS>-verify`, a throwaway clone of the new disk (`windows-verify-vm.yaml`). Its
  cloud-init user data writes a random token to a file; the check passes when the guest agent
  reads that token back. That covers specialize, OOBE, SetupComplete, the guest agent and
  cloudbase-init. Only then is the disk cloned to the boot source, so a bad sysprep never reaches
  the templates. `VERIFY=false` in `os.env` skips it; `VERIFY_TIMEOUT_MIN` (30) bounds it.
  - [x] Ran on snok on 2026-11-16 (win10): the guest agent answered right away, and the token
    came back after 2 min. The check VM and its Secret were then deleted.
- [x] **E2 Monthly patched images.** CronJob `windows-<OS>-rebuild` (in `windows/build`) runs
  the Job's pod template on `REBUILD_SCHEDULE` from `os.env`: one day per version, the 15th to
  the 20th, after Patch Tuesday. Every build (Job or CronJob) is stored as
  `<boot source>-<YYYY-MM>`, checked (E1), then cloned to `<boot source>`. The newest
  `KEEP_BUILDS` (2) dated builds are kept for rollback (`windows/build/README.md`).
  - Design choice: the DataSource is not re-pointed at the dated PVC, because SSP owns the
    Windows DataSources and would likely revert the change. Publishing replaces the
    `<boot source>` PVC instead, so new template clones wait during that clone.
  - The CronJob is suspended by default. A cluster turns it on with the commented patch in
    `clusters/<cluster>/windows/kustomization.yaml`.
  - New RBAC: Role `windows-<OS>-install-image-publish` in `openshift-virtualization-os-images`
    (delete and label PVCs, delete DataVolumes).
  - [x] Checked on snok on 2026-11-16 (win10):
    - First build: `win10-2026-11` was created with its label, then published as `win10`
      (DataSource Ready). The build VM was deleted.
    - A Job created from the CronJob detected rebuild mode and exited ("this month's build
      exists"). Rerunning the Job exited ("boot source exists").
  - [x] Replacing an existing boot source, checked on snok on 2026-11-17 (win2k22 rebuild Job
    from the CronJob). The old `win2k22` PVC was deleted in 7 s and recloned from
    `win2k22-2026-11` (new UID, DataSource Ready again). New template clones boot it.
  - [ ] Not yet checked: pruning past `KEEP_BUILDS`. This needs a third month, or extra dated
    PVCs created by hand.
- [x] **E3 Argo CD health.** `gitopsservice/health` is a kustomization that puts the Lua checks
  into `spec.resourceHealthChecks` of ArgoCD `openshift-gitops` (`oc apply -k
  gitopsservice/health`). The `.lua` files stay separate and are filled in by `replacements`.
  - Checks: HyperConverged (from `setup/`), plus new ones for DataSource and
    VirtualMachinePool.
  - The `setup/` checks for VirtualMachine, VirtualMachineInstance and DataVolume were dropped:
    Argo CD ships those (they came from this repository). Build Jobs and CronJobs use Argo CD's
    built-in batch checks.
  - Removed `setup/` (`install.sh`, `build-resourcecustomizations.sh`, and `change-repo.sh`, which
    rewrote `*/application.yaml` files that no longer exist).
  - `hack/validate.sh` checks every check was filled in, and syntax-checks the Lua when `luac` is
    installed.
  - [x] Applied on snok on 2026-11-16 (GitOps 1.22.3, Argo CD 3.5.6). The operator wrote all
    three checks into `argocd-cm`. Checked against live objects with `argocd admin settings
    resource-overrides health`:
    - HyperConverged: Healthy
    - DataSource `win11`: Healthy
    - DataSource `win10` before its build: Progressing ("PVC not found")
    - VM and DataVolume: Running and ImportInProgress, from Argo CD's built-in checks
- [x] **E4 Example VMs per Windows version.** `examples/windows/<version>` (all six) creates
  `<boot source>-example`, cloned from the DataSource. Its cloudbase-init user data comes from a
  Secret you create from `user-data.example.yaml`: an administrator account, so no password is in
  git. A shared Component (`examples/windows/base`) holds the VM; each version sets
  `BOOT_SOURCE`, `OS_ID` and `DISK_SIZE`, and `win11` adds a TPM. The README shows how to check
  the guest agent's OS info and log on.
  - [x] Ran on snok on 2026-11-16 with win11 (the existing boot source) and win10 (the new
    build). Each clone booted. cloudbase-init created the `example` account (active, in
    Administrators), checked through the guest agent.
  - The guest agent reports `prettyName` "Windows 10 Pro" on Windows 11 (registry
    ProductName); `version` and `kernelRelease` are correct (Windows 11, build 26200).
- [x] **E5 Per-directory READMEs** for `windows/build` (parameters, how to add a version),
  `examples/` and `vms/`.
