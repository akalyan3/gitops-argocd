# gitops-argocd

GitOps platform built on Argo CD. This repo is the single source of truth for the
cluster — Argo CD watches it and reconciles everything automatically, including itself.

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

### 2. Bootstrap

```bash
./scripts/bootstrap.sh
```

Bootstrap does the following in order:
- Creates the `argocd` namespace
- Installs Prometheus Operator CRDs
- Installs Argo CD via Helm with custom values
- Applies the AppProject and root App-of-Apps
- Prints credentials when done

After bootstrap, Git is in control. Do not run it again.

### 3. Access Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 9090:80
```

http://localhost:9090 — username: `admin`, password printed by bootstrap.sh

### 4. Access Grafana

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

http://localhost:3000 — username: `admin`, password: `prom-operator`

Navigate to Dashboards → Argo CD to see the pre-loaded dashboard.

### 5. Access Prometheus

```bash
kubectl port-forward svc/prometheus-prometheus -n monitoring 9091:9090
```

http://localhost:9091

## Verify everything works

### Argo CD apps are synced
```bash
kubectl get applications -n argocd
```
Expected: `argocd-monitoring`, `prometheus-operator`, and `root-app` showing `Synced + Healthy`

### Helm binary override is working
```bash
kubectl exec -n argocd deploy/argocd-repo-server -- /custom-tools/helm version
```
Expected: `version.BuildInfo{Version:"v3.14.4"...}`

### Prometheus is scraping Argo CD
```bash
kubectl port-forward svc/prometheus-prometheus -n monitoring 9091:9090
```
Open http://localhost:9091/targets — look for 5 argocd targets all showing UP

### Grafana dashboard is loaded
Open http://localhost:3000 → Dashboards → search "Argo CD"

### Alerts are configured
```bash
kubectl get prometheusrule -n monitoring
```
Expected: `argocd-alerts` present

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
Kustomize layer on top of Helm for future patching without forking charts.

**Sync waves** — `argocd-self` runs at wave -2, `prometheus-operator` at wave 0,
`argocd-monitoring` at wave 2. This ensures CRDs exist before resources that depend
on them.

**Admission webhooks disabled** — `prometheusOperator.admissionWebhooks.enabled: false`
is set for kind compatibility. Re-enable for production clusters.

**CRD pre-installation** — kube-prometheus-stack CRDs are installed by `bootstrap.sh`
before Argo CD attempts to sync the stack. This is required because Argo CD cannot
apply CRD-dependent resources (ServiceMonitor, PrometheusRule) in the same sync
operation that installs the CRDs themselves.

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
kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite
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
# http://localhost:9091/targets — look for argocd entries showing UP
```

**Grafana dashboard not showing**
```bash
kubectl logs -n monitoring deployment/prometheus-grafana -c grafana-sc-dashboard --tail=20
```

**Sync operation stuck**
```bash
kubectl patch application <name> -n argocd --type merge -p '{"operation":null}'
kubectl rollout restart deployment/argocd-repo-server -n argocd
```
