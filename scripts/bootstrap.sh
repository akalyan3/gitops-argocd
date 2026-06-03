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

echo "==> [1/6] Creating namespace: ${ARGOCD_NAMESPACE}"
kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> [2/6] Adding Helm repos"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==> [3/6] Installing Prometheus Operator CRDs"
CRD_BASE="https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/charts/crds/crds"
for crd in \
  crd-prometheuses.yaml \
  crd-prometheusrules.yaml \
  crd-servicemonitors.yaml \
  crd-alertmanagers.yaml \
  crd-podmonitors.yaml \
  crd-probes.yaml \
  crd-alertmanagerconfigs.yaml; do
  echo "    installing $crd"
  kubectl apply --server-side -f "${CRD_BASE}/${crd}"
done

echo "==> [4/6] Installing Argo CD"
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --version "${ARGOCD_CHART_VERSION}" \
  --values "${REPO_ROOT}/argocd/install/values.yaml" \
  --wait \
  --timeout 10m

echo "==> [5/6] Waiting for Argo CD server"
kubectl rollout status deploy/argocd-server \
  -n "${ARGOCD_NAMESPACE}" --timeout=5m

echo "==> [6/6] Applying AppProject and root App-of-Apps"
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
echo "  kubectl port-forward svc/argocd-server -n argocd 9090:80"
echo "  http://localhost:9090"
echo "  admin / ${ARGOCD_PASSWORD}"
echo ""
echo "  Grafana (once prometheus-operator syncs):"
echo "  kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
echo "  http://localhost:3000 — admin / prom-operator"
echo ""
echo "  Verify Helm binary override:"
echo "  kubectl exec -n argocd deploy/argocd-repo-server -- /custom-tools/helm version"
echo ""
echo "  Watch sync status:"
echo "  kubectl get applications -n argocd -w"
echo ""
