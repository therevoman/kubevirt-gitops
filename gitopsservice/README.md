# OpenShift GitOps settings

| Path | What it is | Apply |
|---|---|---|
| [argocd](argocd) | Settings of the `openshift-gitops` ArgoCD instance: health checks for KubeVirt kinds and the application controller's memory limit | `oc apply -k gitopsservice/argocd` |
| `gitopsservice-infra.yaml` | Runs the GitOps operator's instance on infra nodes (optional; only for clusters with infra nodes) | `oc apply -f gitopsservice/gitopsservice-infra.yaml` |

## Namespace label (required)

The default `openshift-gitops` instance can read the whole cluster, but its application controller
can only create or change resources in namespaces labelled
`argocd.argoproj.io/managed-by=openshift-gitops`. The builds write to two namespaces:

| Namespace | What Argo CD creates there |
|---|---|
| `kubevirt-gitops` | ServiceAccount, ConfigMaps, Roles/RoleBindings, the build Job (PostSync hook), the rebuild CronJob, the ISO DataVolume |
| `openshift-virtualization-os-images` | Roles/RoleBindings that let the build store and publish boot sources |

```
oc create namespace kubevirt-gitops
oc label namespace kubevirt-gitops openshift-virtualization-os-images argocd.argoproj.io/managed-by=openshift-gitops
```

With the label, the GitOps operator gives the instance's controller full rights in the
namespace. Narrower RoleBindings are not enough: the build's RoleBindings grant `admin` and
`os-images.kubevirt.io:edit`, and Kubernetes only lets the controller create a binding when it
holds every permission in it.

Without the label a sync does not fail: it stays `Running` ("one or more tasks are running")
and the Applications stay OutOfSync. Terminate the operation, add the label, and sync again.

The label is set with `oc label` rather than kept as a Namespace manifest here, so `oc delete -k`
can never delete `openshift-virtualization-os-images`, which the SSP operator owns.

## Controller memory

The operator's default limit for the application controller is 2Gi. The controller caches every
resource type in the cluster, so on a cluster with many CRDs (snok has about 640) it is
OOMKilled once syncs start, and every sync stays `Running`. On snok it uses about 2.3Gi after
syncing the six boot-source Applications. `argocd/argocd.yaml` sets
`spec.controller.resources` on the instance (request 2Gi, limit 6Gi), so
`oc apply -k gitopsservice/argocd` applies it on every cluster together with the health checks.
Change it there if a cluster needs more.

Check with `oc get pod openshift-gitops-application-controller-0 -n openshift-gitops`: a
CrashLoopBackOff with last state `OOMKilled` means the limit is still too low.

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
