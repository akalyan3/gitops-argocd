# gitops-argocd

GitOps platform built on Argo CD. This repo is the single source of truth for the cluster — Argo CD watches it and reconciles everything automatically, including itself.

## What gets deployed

| Application | Namespace | Description |
|-------------|-----------|-------------|
| `argocd-self` | `argocd` | Argo CD manages its own lifecycle via App of Apps |
| `prometheus-operator` | `monitoring` | Prometheus, Grafana, and Alertmanager via kube-prometheus-stack |
| `argocd-monitoring` | `monitoring` | ServiceMonitors, PrometheusRules, and Grafana dashboard for Argo CD |

## Prerequisites

- Docker, kind, kubectl, helm

## Deploy

### 1. Create the cluster

```bash
kind create cluster --name gitops --config kind-config.yaml
```

### 2. Install Prometheus Operator CRDs

kube-prometheus-stack requires its CRDs to exist before the operator can sync.
Install them manually before bootstrapping:

```bash
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheuses.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-prometheusrules.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-servicemonitors.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagers.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-podmonitors.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-probes.yaml
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagerconfigs.yaml
```

### 3. Bootstrap

```bash
./scripts/bootstrap.sh
```

Bootstrap installs Argo CD, applies the AppProject and root App-of-Apps, then hands
control to Git. Don't run it again after this.

### 4. Access Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 9090:80
```

http://localhost:9090 — username: `admin`, password printed by bootstrap.sh

### 5. Access Grafana

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

http://localhost:3000 — username: `admin`, password: `prom-operator`

### 6. Access Prometheus

```bash
kubectl port-forward svc/prometheus-prometheus -n monitoring 9091:9090
```

http://localhost:9091

## Making changes

Edit a file, commit, push. Argo CD handles the rest.

## Design decisions

**App of Apps** — A single `root-app.yaml` is applied once by `bootstrap.sh`. It points
Argo CD at `argocd/apps/` which contains an `ApplicationSet` generating all child
Applications. Every subsequent change goes through Git.

**Helm binary replacement** — An init container in `argocd-repo-server` downloads
Helm v3.14.4 into a shared `emptyDir` volume. The `HELM_BINARY_PATH` env var points
Argo CD at the custom binary. No custom Docker image required — changing the version
is a single string edit in `argocd/install/values.yaml`.

**Kustomize + helmCharts** — Both Argo CD and kube-prometheus-stack are rendered via
Kustomize's `helmCharts` feature rather than native Helm Applications. This gives a
Kustomize layer on top of Helm for patching without forking charts.

**Sync waves** — `argocd-self` runs at wave -2, `prometheus-operator` at wave 0, and
`argocd-monitoring` at wave 2. This ensures CRDs exist before resources that depend
on them.

**Admission webhooks disabled** — `prometheusOperator.admissionWebhooks.enabled: false`
is set for kind compatibility. Re-enable for production clusters.

## Assumptions

- Single cluster — Argo CD and workloads run in the same cluster
- Public GitHub repo — no Git credentials needed
- Default storage class used for Prometheus PVCs
- Helm v3.14.4 injected as the custom binary — change the version string in
  `argocd/install/values.yaml`

## Troubleshooting

**Argo CD pods not starting**
```bash
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --previous
```

**App stuck in Progressing or Unknown**
```bash
kubectl describe application <name> -n argocd
```

**Custom Helm binary not applied**
```bash
kubectl exec -n argocd deploy/argocd-repo-server -- /custom-tools/helm version
kubectl logs -n argocd deploy/argocd-repo-server -c helm-installer
```

**Prometheus not scraping Argo CD**
```bash
kubectl get servicemonitor -n monitoring
kubectl port-forward svc/prometheus-prometheus -n monitoring 9091:9090
# http://localhost:9091/targets
```

**Grafana dashboard not showing**
```bash
kubectl logs -n monitoring deployment/prometheus-grafana -c grafana-sc-dashboard --tail=20
```
