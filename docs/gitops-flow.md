# End-to-End GitOps Flow

What happens between a `git push` and pods running in the cluster.

## Components

| Component | Role |
|-----------|------|
| Git server | Source of truth — stores all desired-state manifests |
| argocd-server | API gateway and UI — handles user and CLI requests |
| application-controller | Reconciliation engine — compares live state vs desired state |
| repo-server | Fetches and renders manifests from Git |
| kube-apiserver | Accepts resource mutations, enforces RBAC and admission |

## Flow

1. Developer runs `git push`
2. GitHub receives the commit
3. Argo CD becomes aware via webhook POST to argocd-server, or polling every ~3 minutes
4. argocd-server notifies application-controller of the affected Application
5. application-controller queues a refresh
6. application-controller calls repo-server to render manifests
7. repo-server fetches the repo, detects source type (Helm/Kustomize/YAML), renders and returns manifests
8. application-controller diffs desired state (Git) vs live state (cluster)
9. Drift detected — Application marked OutOfSync
10. application-controller applies resources to kube-apiserver via apply
11. kube-apiserver authenticates, runs admission webhooks, persists to etcd
12. kube-controller-manager and kubelet create pods and start containers
13. application-controller watches health via informers and marks Application Synced + Healthy

## Key points

**Webhook vs polling** — Webhooks make sync near-instant. Without a webhook Argo CD
polls every ~3 minutes. For a local kind setup polling is fine. For production configure
a webhook in GitHub pointing at /api/webhook on your Argo CD server.

**repo-server caching** — repo-server maintains a local Git cache keyed by repo URL
and revision. It does not clone on every sync, only on cache miss or when a new commit
is detected. Restarting repo-server clears the cache — useful when debugging manifest
rendering issues.

**kustomize.buildOptions** — When using Kustomize with helmCharts, Argo CD requires
`--enable-helm` to be set. This is configured globally in `argocd-cm` via
`kustomize.buildOptions: --enable-helm` in `argocd/install/values.yaml`. Without this,
repo-server fails to render any Kustomize application that references a Helm chart.

**Three-way diff** — Argo CD diffs desired (Git) vs live (cluster) vs last-applied.
Handles fields Kubernetes mutates after apply without treating them as drift. Fields
not declared in the schema (e.g. `.status.terminatingReplicas`) can cause comparison
errors — fix by adding them to `resource.customizations.ignoreDifferences` in argocd-cm.

**selfHeal** — If someone manually edits a resource in the cluster, application-controller
detects the drift on its next reconciliation and reverts it back to what Git says.

**Sync waves** — Resources annotated with `argocd.argoproj.io/sync-wave` are applied
in order. Wave -2 (argocd-self) completes before wave 0 (prometheus-operator), which
completes before wave 2 (argocd-monitoring). This ensures CRDs exist before resources
that depend on them.

**CRD bootstrapping** — kube-prometheus-stack installs CRDs as part of its Helm chart.
However, when Argo CD tries to sync the full chart including CRD-dependent resources
(ServiceMonitor, PrometheusRule, Alertmanager) in a single operation, it fails because
the CRDs don't exist yet at sync time. The solution is to pre-install the CRDs before
the first sync:

```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheuses.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheusrules.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-servicemonitors.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagers.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-podmonitors.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-probes.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagerconfigs.yaml
```

**Admission webhooks on kind** — kube-prometheus-stack's admission webhooks use
pre-sync hooks that create ClusterRoles and ClusterRoleBindings. On kind these conflict
with resources left over from previous sync attempts, causing the sync to hang. Disabled
via `prometheusOperator.admissionWebhooks.enabled: false` in `prometheus/operator/values.yaml`.
Re-enable for production clusters.

**ServiceMonitor label and port matching** — Prometheus only picks up ServiceMonitors
whose labels match the `serviceMonitorSelector` on the Prometheus CR. The
kube-prometheus-stack default requires `release: prometheus` on every ServiceMonitor.
Additionally, the `port` field in the ServiceMonitor endpoint must match the port name
on the Kubernetes Service exactly — not the port number. For Argo CD, the metrics
services expose a port named `http-metrics`, not `metrics`.

**argocd-self bootstrap conflict** — When Argo CD is first installed via Helm and then
configured to manage itself via GitOps, pre-sync hooks (specifically `argocd-redis-secret-init`)
create RBAC resources that already exist from the initial Helm install. This causes the
hook to fail on subsequent syncs. This is a known bootstrapping race condition specific
to the self-management pattern.

## Debugging a stuck sync

```bash
# Check application conditions
kubectl describe application <name> -n argocd

# application-controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# repo-server logs (manifest rendering errors show here)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Force a hard refresh
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Terminate a stuck sync operation
kubectl patch application <name> -n argocd --type merge -p '{"operation":null}'

# Restart repo-server to clear manifest cache
kubectl rollout restart deployment/argocd-repo-server -n argocd
```
