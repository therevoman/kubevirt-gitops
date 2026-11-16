# Demo VMs

`fedora-gitops1` and `centos-gitops1` clone the `fedora` and `centos-stream9` DataSources in
`openshift-virtualization-os-images`. Neither has a password. The QEMU guest agent adds the SSH
public key from Secret `vm-ssh-key` to the `fedora` / `centos` user.

```
oc new-project vms-demo
oc create secret generic vm-ssh-key -n vms-demo --from-file=key=$HOME/.ssh/id_ed25519.pub
oc apply -k vms/overlays/openshift -n vms-demo
virtctl ssh fedora@vm/fedora-gitops1 -n vms-demo
```

Create the Secret first: the VMs don't start without it.
