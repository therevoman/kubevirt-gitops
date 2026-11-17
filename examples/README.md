# Examples

Demos of `VirtualMachinePool`, and one example VM per Windows boot source. Nothing here is deployed by Argo CD; apply one by hand with
`oc apply -k examples/<name>`. `vmpools` has no kustomization, so use `oc apply -f examples/vmpools`.

| Directory | What it shows |
|---|---|
| `pool-of-fedoras` | Fedora pool with per-VM cloud-init Secrets, a Service and a Route (see its README) |
| `pool-of-vms` | Minimal VirtualMachinePool in its own namespace |
| `virtualmachinepool` | Pool scaled by a HorizontalPodAutoscaler, behind a Service |
| `vmpools` | Pool with cloud-init that installs a web page, an HPA and a Service |
| `win2k19virtualmachinepool` | Windows Server 2019 pool cloned from the `win2k19` boot source, with an HPA |
| `environment` | An example environment for the Windows boot sources: `settings/` (`ISO_BASE_URL`, rebuild toggle) and one overlay per version. The template for a config repository (see the top-level README, "Deploying from a config repo"); CI renders it |
| [`windows`](windows) | One VM per Windows version (`win10` ... `win2k25`), cloned from its DataSource with cloudbase-init user data from a Secret you create |

**Demo credentials only.** The pool examples contain fixed passwords (`redhat`, `EXAMPLE`) and a
lab SSH public key. Don't use them outside a lab. `windows` has no credentials in git. This is tracked as item 1.3 in
[docs/architecture-review.md](../docs/architecture-review.md).
