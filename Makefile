.DEFAULT_GOAL := help
SHELL := /bin/bash
CLUSTER_NAME := devops-lab
CHART_DIR := manifests/helm/devops-api

.PHONY: help bootstrap cluster-down restore smoke drift canary lint secrets status port-forward-argocd port-forward-api

help: ## Lista todos os atalhos disponíveis
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Sobe Kind + Envoy Gateway + ESO/SOPS + ArgoCD + dev & staging
	./scripts/bootstrap.sh

cluster-down: ## Apaga completamente o cluster Kind
	kind delete cluster --name $(CLUSTER_NAME)

restore: cluster-down bootstrap smoke ## Apaga o cluster e restaura tudo do zero só a partir do Git

smoke: ## Testa a API via port-forward e via Gateway API (dev e staging)
	./scripts/smoke-test.sh

drift: ## Demonstra drift manual no cluster e o ArgoCD corrigindo (self-heal)
	./scripts/demo-drift.sh

canary: ## Demonstra o desafio opcional Argo Rollouts Canary (20% -> 50% -> 100%) na Gateway API
	./scripts/demo-canary.sh

lint: ## Valida o Helm chart (values-dev e values-staging), kustomize do ArgoCD e schemas reais (incluindo CRDs) no kubeconform
	helm lint $(CHART_DIR) -f $(CHART_DIR)/values.yaml -f $(CHART_DIR)/values-dev.yaml
	helm lint $(CHART_DIR) -f $(CHART_DIR)/values.yaml -f $(CHART_DIR)/values-staging.yaml
	helm lint $(CHART_DIR) -f $(CHART_DIR)/values.yaml --set rollout.enabled=true
	helm template devops-api-dev $(CHART_DIR) -n dev -f $(CHART_DIR)/values.yaml -f $(CHART_DIR)/values-dev.yaml > /tmp/rendered-dev.yaml
	helm template devops-api-staging $(CHART_DIR) -n staging -f $(CHART_DIR)/values.yaml -f $(CHART_DIR)/values-staging.yaml > /tmp/rendered-staging.yaml
	kubectl kustomize manifests/argocd > /tmp/argocd-apps.yaml
	docker run --rm -v /tmp:/rendered:ro -v "$$PWD:/repo:ro" ghcr.io/yannh/kubeconform:v0.6.7 \
		-strict -summary -verbose \
		-schema-location default \
		-schema-location '/repo/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		/rendered/rendered-dev.yaml /rendered/rendered-staging.yaml /rendered/argocd-apps.yaml \
		/repo/infrastructure/gateway/envoy-gateway.yaml /repo/infrastructure/external-secrets/cluster-secret-store.yaml
	@echo "✅ Helm chart, CRDs (HTTPRoute, ExternalSecret, Rollout, Application) e manifests ArgoCD válidos!"

secrets: ## Verifica com Gitleaks que nenhum segredo em texto puro entrou no Git
	docker run --rm -v "$$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --verbose --exit-code 1

status: ## Mostra o estado das Applications no ArgoCD, Gateway e Pods em dev/staging
	kubectl get applications -n argocd
	kubectl get gateway -n envoy-gateway-system
	kubectl get httproute -A
	kubectl get externalsecret -A
	kubectl get pods -n dev
	kubectl get pods -n staging

port-forward-argocd: ## Abre a UI do ArgoCD em https://localhost:8444 (admin)
	@echo "Senha inicial do admin:"
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo ""
	kubectl port-forward svc/argocd-server -n argocd 8444:443

port-forward-api: ## Faz port-forward direto do Service da API em dev (http://localhost:8000)
	kubectl port-forward -n dev svc/devops-api-dev 8000:8000
