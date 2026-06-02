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
10. application-controller applies resources to kube-apiserver via Server-Side Apply
11. kube-apiserver authenticates, runs admission webhooks, persists to etcd
12. kube-controller-manager and kubelet create pods and start containers
13. application-controller watches health via informers and marks Application Synced + Healthy

## Key points

**Webhook vs polling** — Webhooks make sync near-instant. Without a webhook
Argo CD polls every ~3 minutes. For a local kind setup polling is fine.
For production configure a webhook in GitHub pointing at /api/webhook.

**repo-server caching** — repo-server maintains a local Git cache keyed by
repo URL and revision. It does not clone on every sync, only on cache miss
or when a new commit is detected.

**Three-way diff** — Argo CD diffs desired (Git) vs live (cluster) vs
last-applied. Handles fields Kubernetes mutates after apply without
treating them as drift.

**selfHeal** — If someone manually edits a resource in the cluster,
application-controller detects the drift on its next reconciliation
and reverts it back to what Git says.

**Sync waves** — Resources annotated with argocd.argoproj.io/sync-wave
are applied in order. Wave -2 (argocd-self) completes before wave 0
(prometheus-operator), which completes before wave 2 (argocd-monitoring).
This ensures CRDs exist before resources that depend on them.

## Debugging a stuck sync

```bash
kubectl describe application <name> -n argocd
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server
```
