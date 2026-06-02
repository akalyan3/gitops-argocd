#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="argocd"
ARGOCD_CHART_VERSION="7.1.3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Checking prerequisites..."
for cmd in kubectl helm git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found"; exit 1
  fi
done

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot reach Kubernetes cluster. Check your kubeconfig."; exit 1
fi

echo "==> [1/5] Creating namespace: ${ARGOCD_NAMESPACE}"
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [2/5] Adding Helm repos"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==> [3/5] Installing Argo CD"
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${REPO_ROOT}/argocd/install/values.yaml" \
  --wait \
  --timeout 10m

echo "==> [4/5] Waiting for Argo CD server"
kubectl rollout status deploy/argocd-server \
  -n "${ARGOCD_NAMESPACE}" --timeout=5m

echo "==> [5/5] Applying AppProject and root App-of-Apps"
kubectl apply -f "${REPO_ROOT}/argocd/projects/platform-project.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/apps/root-app.yaml"

ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n "${ARGOCD_NAMESPACE}" \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "========================================="
echo "  Bootstrap complete!"
echo "========================================="
echo ""
echo "  Argo CD:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080"
echo "  admin / ${ARGOCD_PASSWORD}"
echo ""
echo "  Grafana (once prometheus-operator syncs):"
echo "  kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
echo "  http://localhost:3000 — admin / prom-operator"
echo ""
