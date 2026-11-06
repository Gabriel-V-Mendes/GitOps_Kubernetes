#!/usr/bin/env bash
# ==============================================================================
# Bootstrap Declarativo Completo — Cluster Kind + Gateway API + ESO/SOPS + ArgoCD
#
# Uso:
#   ./scripts/bootstrap.sh
#
# Este script reconstrói 100% do estado do cluster a partir do Git (Disaster Recovery).
# Se o cluster for apagado (`kind delete cluster --name devops-lab`), basta rodar
# este comando para restaurar a infraestrutura e os ambientes `dev` e `staging`.
# ==============================================================================
set -euo pipefail

CLUSTER_NAME="devops-lab"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_REPO_DIR="$(cd "$ROOT_DIR/../projeto_devops" 2>/dev/null && pwd || (cd "$ROOT_DIR/.." && pwd))"
API_IMAGE="ghcr.io/gabriel-v-mendes/containerizacaopipelinecicd:sha-812ed49cfee329733e1ed56d5145d3a36cbb3edb"
POSTGRES_IMAGE="postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24"

# Versões explícitas de todos os controladores de infraestrutura (reprodutibilidade)
ENVOY_GATEWAY_VERSION="v1.3.0"
EXTERNAL_SECRETS_VERSION="2.14.0"
ARGO_ROLLOUTS_VERSION="v1.7.2"
ARGOCD_VERSION="v3.5.6"

echo "=================================================================="
echo "1/7 · Cluster Kind ($CLUSTER_NAME)"
echo "=================================================================="
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --config "$ROOT_DIR/infrastructure/kind/kind-config.yaml"
else
  echo "Cluster '$CLUSTER_NAME' já existe. Reutilizando..."
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

echo "=================================================================="
echo "2/7 · Pré-carregando imagens da API (Projeto 1) no Kind"
echo "=================================================================="
if ! docker image inspect "$API_IMAGE" >/dev/null 2>&1; then
  if [ -f "$APP_REPO_DIR/Dockerfile" ]; then
    echo "Construindo imagem da API do Projeto 1 localmente..."
    docker build -t "$API_IMAGE" "$APP_REPO_DIR"
  else
    echo "Baixando imagem da API do GHCR..."
    docker pull "$API_IMAGE"
  fi
fi
kind load docker-image "$API_IMAGE" --name "$CLUSTER_NAME"

echo "=================================================================="
echo "3/7 · Gateway API + Envoy Gateway Controller ($ENVOY_GATEWAY_VERSION)"
echo "=================================================================="
if ! helm status eg -n envoy-gateway-system >/dev/null 2>&1; then
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$ENVOY_GATEWAY_VERSION" \
    --namespace envoy-gateway-system \
    --create-namespace \
    --wait --timeout 5m
fi
kubectl apply -f "$ROOT_DIR/infrastructure/gateway/envoy-gateway.yaml"
kubectl wait --for=condition=Programmed gateway/shared-gateway -n envoy-gateway-system --timeout=90s
kubectl wait --for=condition=Ready pod -l gateway.envoyproxy.io/owning-gateway-name=shared-gateway -n envoy-gateway-system --timeout=120s

echo "=================================================================="
echo "4/7 · External Secrets Operator ($EXTERNAL_SECRETS_VERSION) + SOPS"
echo "=================================================================="
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null 2>&1
if ! helm status external-secrets -n external-secrets >/dev/null 2>&1; then
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --version "$EXTERNAL_SECRETS_VERSION" \
    --namespace external-secrets \
    --create-namespace \
    --set installCRDs=true \
    --wait --timeout 5m
fi

# Descriptografa o Secret semente com SOPS + age apenas em memória (nunca grava em disco)
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [ -f "$AGE_KEY_FILE" ] || [ -n "${SOPS_AGE_KEY:-}" ]; then
  echo "Descriptografando postgres-source-secret.sops.yaml via SOPS + age..."
  SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
    sops --config "$ROOT_DIR/.sops.yaml" -d "$ROOT_DIR/infrastructure/secrets/postgres-source-secret.sops.yaml" \
    | kubectl apply -f -
else
  echo "Chave age local não encontrada em $AGE_KEY_FILE; gerando par de chaves age..."
  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  age-keygen -o "$AGE_KEY_FILE"
  chmod 600 "$AGE_KEY_FILE"
  kubectl create secret generic postgres-source-secret \
    --namespace external-secrets \
    --from-literal=username=devops \
    --from-literal=password="$(openssl rand -hex 20)" \
    --from-literal=database=devops \
    --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl apply -f "$ROOT_DIR/infrastructure/external-secrets/cluster-secret-store.yaml"
kubectl wait --for=condition=Ready clustersecretstore/k8s-secret-store --timeout=60s

echo "=================================================================="
echo "5/7 · Argo Rollouts ($ARGO_ROLLOUTS_VERSION) + Gateway API Plugin"
echo "=================================================================="
kubectl apply -f "$ROOT_DIR/infrastructure/rollouts/namespace.yaml"
kubectl apply -n argo-rollouts \
  -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml"
kubectl apply -f "$ROOT_DIR/infrastructure/rollouts/namespace.yaml"
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=120s

echo "=================================================================="
echo "6/7 · ArgoCD ($ARGOCD_VERSION — GitOps Controller)"
echo "=================================================================="
kubectl apply -f "$ROOT_DIR/infrastructure/argocd/namespace.yaml"
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "Aguardando pods do ArgoCD ficarem prontos..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=180s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=180s

echo "=================================================================="
echo "7/7 · Aplicando Applications do ArgoCD (dev e staging)"
echo "=================================================================="
kubectl apply -k "$ROOT_DIR/manifests/argocd"

echo "Aguardando ArgoCD sincronizar e criar os workloads em 'dev' e 'staging'..."
for ns in dev staging; do
  echo -n "Aguardando workloads em '$ns' serem criados pelo ArgoCD"
  for _ in $(seq 1 60); do
    if kubectl get statefulset "devops-api-${ns}-postgres" -n "$ns" >/dev/null 2>&1 && \
       { kubectl get deployment "devops-api-${ns}" -n "$ns" >/dev/null 2>&1 || \
         kubectl get rollout.argoproj.io "devops-api-${ns}" -n "$ns" >/dev/null 2>&1; }; then
      echo " OK!"
      break
    fi
    echo -n "."
    sleep 3
  done
  kubectl rollout status "statefulset/devops-api-${ns}-postgres" -n "$ns" --timeout=180s
  if kubectl get deployment "devops-api-${ns}" -n "$ns" >/dev/null 2>&1; then
    kubectl rollout status "deployment/devops-api-${ns}" -n "$ns" --timeout=180s
  else
    kubectl wait --for=condition=Available "rollout.argoproj.io/devops-api-${ns}" -n "$ns" --timeout=180s
  fi
done

echo ""
echo "✅ Cluster restaurado com sucesso a partir do Git!"
kubectl get applications -n argocd
kubectl get pods -n dev
kubectl get pods -n staging
