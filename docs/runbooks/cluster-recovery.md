# Runbook: Disaster Recovery — Apagar o Cluster e Restaurar 100% a partir do Git

## Cenário
O cluster Kubernetes local (`kind`) foi completamente destruído (acidentalmente, por falha da máquina ou para validar a imutabilidade do estado no Git).

**Objetivo:** provar que nenhum estado de configuração residia apenas "na mão" dentro do cluster e que todo o ambiente (`dev` e `staging`, banco PostgreSQL, segredos, Gateway API e ArgoCD) é restaurado exclusivamente a partir do Git.

---

## Procedimento Automatizado (Um Comando)

```bash
# Apaga o cluster atual, recria do zero, instala controladores, sincroniza ArgoCD e roda smoke tests:
make restore
```

---

## Procedimento Passo a Passo (O que o `make restore` executa)

### 1. Destruir o cluster existente
```bash
kind delete cluster --name devops-lab
```

### 2. Recriar o cluster e toda a pilha GitOps a partir do Git
```bash
./scripts/bootstrap.sh
```
Internamente, o `bootstrap.sh` executa:
1. `kind create cluster --config infrastructure/kind/kind-config.yaml` (mapeando `127.0.0.1:8080 -> NodePort 30080`).
2. Carrega a imagem da API do Projeto 1 (`ghcr.io/gabriel-v-mendes/containerizacaopipelinecicd:sha-...`) no Kind.
3. Instala o **Envoy Gateway** (`v1.3.0`) e aplica `infrastructure/gateway/envoy-gateway.yaml` (`EnvoyProxy`, `GatewayClass` e `Gateway`).
4. Instala o **External Secrets Operator** (`2.14.0`), descriptografa em memória o segredo semente com **SOPS + age** (`infrastructure/secrets/postgres-source-secret.sops.yaml`) e aplica o `ClusterSecretStore`.
5. Instala o **Argo Rollouts** (`v1.7.2`) com o plugin oficial de Gateway API (`v0.17.0`).
6. Instala o **ArgoCD** (`v3.5.6`) no namespace `argocd`.
7. Aplica `kubectl apply -k manifests/argocd` (`devops-api-dev` e `devops-api-staging`).

### 3. Validar a restauração completa (`port-forward` + Gateway API)
```bash
./scripts/smoke-test.sh
```
Verifica:
- `GET /health` e `GET /health/ready` via `kubectl port-forward`.
- `GET /health`, `GET /health/ready`, `POST /items` e `GET /items` via **Gateway API** (`http://127.0.0.1:8080` com `Host: dev.api.local` e `Host: staging.api.local`).
