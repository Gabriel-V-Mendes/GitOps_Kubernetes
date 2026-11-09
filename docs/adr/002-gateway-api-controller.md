# ADR-002: Substituição do Ingress NGINX pela Gateway API (Envoy Gateway) no Kind

## Status
Aceito

## Contexto
1. **Aposentadoria do Ingress NGINX:** O projeto `kubernetes/ingress-nginx` entrou em modo de manutenção/aposentadoria pelo Kubernetes SIG Network em favor da **Gateway API** (`gateway.networking.k8s.io/v1`).
2. **Limitações da API `Ingress` legada:** A API `Ingress` dependia de dezenas de `annotations` proprietárias e não padronizadas para recursos básicos (como divisão de tráfego canário, reescrita de cabeçalhos e timeouts) e misturava responsabilidades de infraestrutura (LoadBalancer/TLS) e de desenvolvimento (rotas HTTP) num único objeto.
3. **Desafio específico do `kind`:** Em clusters locais `kind` (Kubernetes in Docker), não há um provedor de nuvem para alocar IPs externos em Services do tipo `LoadBalancer` (eles ficam eternamente `<pending>`). O tráfego do host (`localhost:8080`) chega ao nó do Kind via `extraPortMappings`, o que exige que o data-plane do Gateway escute num **`NodePort` estático e previsível** (ex.: `30080`).

## Pesquisa de Controllers da Gateway API para `kind`

Antes de escolher o controller, avaliamos as 5 principais implementações da Gateway API (`v1`) rodando em `kind`:

| Controller | Conformidade Gateway API | Suporte a `NodePort` fixo no `kind` (sem MetalLB) | Consumo de RAM no `kind` | Suporte a Canary (`HTTPRoute` weights) | Veredito |
|---|---|---|---|---|---|
| **Envoy Gateway** (`envoyproxy/gateway-helm`) | Total (Core + Extended, projeto oficial CNCF) | **Excelente:** CRD `EnvoyProxy` permite definir `envoyService.type: NodePort` e fixar `nodePort: 30080` via patch declarativo | ~110 MB (control-plane + 1 pod Envoy compartilhado) | Nativo (plugin oficial do Argo Rollouts) | **Escolhido** |
| **NGINX Gateway Fabric** (`nginx-gateway-fabric`) | Core (sucessor oficial do Ingress NGINX pela F5) | Bom via `NginxProxy` / Helm values, porém cria data-plane acoplado | ~90 MB | Nativo (`weight` em `backendRefs`) | Boa alternativa |
| **Traefik v3** (`traefik/traefik`) | Core | Bom via Helm (`ports.web.nodePort=30080`), mas mistura CRDs legados (`IngressRoute`) com Gateway API | ~65 MB | Parcial (foco histórico em CRDs próprios) | Bom para setups mínimos |
| **Cilium** (Gateway API) | Core + eBPF | Exige substituir o CNI padrão do Kind (`kindnet`) e instalar L2 Announcements / kube-proxy replacement | ~350 MB+ | Nativo | Pesado demais para lab local |
| **Istio** (Gateway API) | Core + Mesh | Por padrão cria `LoadBalancer` por `Gateway`; exige anotações/patches manuais por Service | ~400 MB+ (`istiod` + gateways) | Nativo | Sobrecarga desnecessária sem Service Mesh |

## Decisão
Escolhemos o **Envoy Gateway** (`v1.10.0`, versão estável atualizada da anterior `v1.3.0`, distribuído via OCI chart `oci://docker.io/envoyproxy/gateway-helm`) combinado com um `Gateway` compartilhado (`shared-gateway` no namespace `envoy-gateway-system`) e rotas `HTTPRoute` por ambiente (`dev.api.local` no namespace `dev` e `staging.api.local` no namespace `staging`).

A progressão adotada no projeto segue duas etapas:
1. **Etapa inicial com `kubectl port-forward`:** valida diretamente o `Service` (`ClusterIP`) da API sem depender de nenhuma camada de roteamento externo.
2. **Etapa completa com Gateway API (`GatewayClass` + `Gateway` + `HTTPRoute`):** expõe `dev` e `staging` na porta `8080` do host (`30080` no nó do Kind via `EnvoyProxy`), separando o tráfego pelo header HTTP `Host` (`dev.api.local` e `staging.api.local`).

## Consequências
- **Positivas:**
  - Alinhado ao padrão futuro do Kubernetes (`gateway.networking.k8s.io/v1`), sem nenhuma annotation proprietária nas rotas da aplicação.
  - Separação clara de papéis: plataforma gerencia `EnvoyProxy`, `GatewayClass` e `Gateway` em `infrastructure/gateway/`; desenvolvedores gerenciam apenas `HTTPRoute` no Helm chart da aplicação.
  - Funciona 100% nativamente no `kind` via `extraPortMappings` sem precisar instalar MetalLB.
  - Habilita divisão real de tráfego por peso (`weight`) caso o desafio opcional de **Argo Rollouts** seja ativado.
- **Negativas:**
  - Requer a instalação prévia do chart do Envoy Gateway (automatizada no `scripts/bootstrap.sh`).
