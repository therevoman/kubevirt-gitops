# Windows example VMs

One VM per Windows version, cloned from that version's boot source (DataSource `win10`, `win11`,
`win2k16`, `win2k19`, `win2k22`, `win2k25` in `openshift-virtualization-os-images`). Use them to
check an image end to end: clone, first boot (specialize, OOBE), cloudbase-init user data, guest
agent, and logon with an account the user data created.

The build's own image check (`windows/build/README.md`) runs the same kind of clone
automatically before it publishes a boot source. These examples are for trying an image by hand.

## Run one

1. Create the user data Secret in your namespace. Copy
   [`user-data.example.yaml`](user-data.example.yaml) and set your own user name and password;
   don't commit the copy:

   ```
   oc create secret generic windows-example-userdata --from-file=userdata=my-user-data.yaml -n <namespace>
   ```

2. Create the VM: `oc apply -k examples/windows/win11 -n <namespace>`. It is named
   `win11-example` (`<boot source>-example`). The clone waits until the DataSource is Ready.

3. Check it:

   ```
   oc get vmi win11-example -n <namespace> -o jsonpath='{.status.guestOSInfo.prettyName}{"\n"}'
   virtctl vnc win11-example -n <namespace>
   ```

   The first command shows the Windows version once the guest agent runs. In the VNC console, log
   on with the account from your user data. cloudbase-init's log is in
   `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\`.

4. Delete it: `oc delete -k examples/windows/win11 -n <namespace>`. The root disk goes with the VM.

## How it is built

| Path | What it is |
|---|---|
| `base/` | Kustomize Component: the VM (SATA disk like the build VM, virtio NIC, EFI secure boot, Hyper-V enlightenments) and the replacements that name it |
| `<version>/` | `BOOT_SOURCE`, `OS_ID` and `DISK_SIZE` for that version (same values as `<version>/base/os.env`); `win11` also adds a TPM |
| `user-data.example.yaml` | cloud-config for cloudbase-init: creates an administrator account |

The boot sources keep cloudbase-init's own account plugins off (see `post-install.ps1`). An
account comes from the user data, a sysprep volume, or the guest agent.
