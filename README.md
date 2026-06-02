# gitops-argocd

GitOps platform built on Argo CD. This repo is the single source of truth for the cluster — Argo CD watches it and reconciles everything automatically, including itself.

## What gets deployed

| Application | Namespace | Description |
|-------------|-----------|-------------|
| `argocd-self` | `argocd` | Argo CD manages its own lifecycle |
| `prometheus-operator` | `monitoring` | Prometheus, Grafana, and Alertmanager |
| `argocd-monitoring` | `monitoring` | ServiceMonitors, alerts, and dashboards for Argo CD |

## Prerequisites

- Docker, kind, kubectl, helm

## Deploy

```bash
# 1. Create the cluster
kind create cluster --name gitops --config kind-config.yaml

# 2. Bootstrap — run once
./scripts/bootstrap.sh
```

Bootstrap installs Argo CD and applies the root App-of-Apps. After that Git is in control — don't run it again.

## Access

```bash
# Argo CD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080 — admin / password printed by bootstrap.sh

# Grafana
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
# http://localhost:3000 — admin / prom-operator
```

## Making changes

Edit a file, commit, push. Argo CD handles the rest.

## Assumptions

- Single cluster
- Public GitHub repo — no credentials needed
- Helm 3.14.4 injected as the custom binary — change the version in `argocd/install/values.yaml`
- Default storage class used for Prometheus PVCs
