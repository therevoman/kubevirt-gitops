# OpenShift GitOps settings

| Path | What it is | Apply |
|---|---|---|
| [health](health) | Argo CD health checks for KubeVirt kinds, in the `openshift-gitops` ArgoCD instance | `oc apply -k gitopsservice/health` |
| `gitopsservice-infra.yaml` | Runs the GitOps operator's instance on infra nodes, and creates the namespaces with the `argocd.argoproj.io/managed-by` label | `oc apply -f gitopsservice/gitopsservice-infra.yaml` |

## Health checks

Argo CD shows a resource as Healthy as soon as it exists, unless it has a health check for the
kind. Argo CD ships checks for `kubevirt.io` VirtualMachine and VirtualMachineInstance and for
`cdi.kubevirt.io` DataVolume. These came from this repository's original scripts, so they are not
overridden. `health/` adds the kinds it lacks:

| Kind | Healthy | Otherwise |
|---|---|---|
| `hco.kubevirt.io` HyperConverged | `Available` condition True | Degraded on `Degraded`, else Progressing |
| `cdi.kubevirt.io` DataSource | `Ready` condition True | Progressing (for example while a boot source builds) |
| `pool.kubevirt.io` VirtualMachinePool | `readyReplicas` reaches `replicas` | Suspended when paused, else Progressing |

Each check is a `.lua` file. `kustomization.yaml` puts the files into
`spec.resourceHealthChecks` of ArgoCD `openshift-gitops/openshift-gitops`, the instance the
operator creates. That replaces the whole `resourceHealthChecks` list of the instance; add any
other checks you need there. The operator restarts Argo CD with the new checks.

This replaces the old `setup/` scripts, which printed a `resourceCustomizations` patch from the
live cluster and rewrote `repoURL`s.
