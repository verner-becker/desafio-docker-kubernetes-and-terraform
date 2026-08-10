# Mural de Recados — Docker + Kubernetes + Terraform

Solução do desafio "Do compose ao cluster". O enunciado original está em
[`docs/enunciado-original.md`](docs/enunciado-original.md); este README
documenta as decisões tomadas e como rodar.

## Como rodar

Pré-requisitos: Docker, `kind`, `kubectl`, `helm`, `terraform` (>= 1.6).

### 1. docker-compose (só para entender a app)

```bash
docker compose up --build
# abra http://localhost:8080
```

### 2. Ciclo completo via Terraform

```bash
cd infra/terraform
terraform init
terraform apply     # cluster kind do zero -> app respondendo
# abra http://mural.localtest.me

terraform apply     # roda de novo: 0 added, 0 changed, 0 destroyed
terraform destroy   # remove tudo
```

`*.localtest.me` resolve para `127.0.0.1` publicamente — não precisa mexer
em `/etc/hosts`.

### Atalhos (Makefile)

```bash
make compose-up / compose-down   # docker-compose
make up / make plan / make down  # ciclo Terraform
make lint / make validate        # helm lint + terraform validate
make load-test                   # bônus: gera carga e mostra o HPA escalando
```

## Bônus

### HPA (autoscaling da API)

`infra/helm/mural/templates/hpa.yaml` — `HorizontalPodAutoscaler` (v2) na
API, mirando 50% de utilização de CPU sobre o `request` configurado (50m),
entre 1 e 5 réplicas. Parametrizável via `values.yaml`
(`autoscaling.enabled/minReplicas/maxReplicas/targetCPUUtilizationPercentage`)
e ligado por padrão pelo Terraform (`var.autoscaling_enabled`).

Duas coisas precisavam existir pra isso funcionar de verdade:

- **metrics-server**: kind não vem com ele. Sem uma fonte de métricas de
  CPU/memória, o HPA fica com `<unknown>` pra sempre. O Terraform instala o
  chart oficial (`helm_release.metrics_server`) com `--kubelet-insecure-tls`
  — necessário porque o kubelet do kind não expõe um certificado que o
  metrics-server valide por padrão (comum em cluster local).
- **`replicas` condicional no Deployment**: quando `autoscaling.enabled`,
  o template da API *não* fixa `spec.replicas` — se fixasse, cada
  `helm upgrade` reverteria o número de réplicas que o HPA tivesse ajustado
  por conta própria, brigando com o autoscaler.

### Prova de escala sob carga

Com o cluster no ar (`make up`), gerei carga com `k6`
(`scripts/load-test.js`, 80 VUs por 3 minutos) contra
`http://mural.localtest.me/api/messages` e acompanhei `kubectl get hpa -n
mural -w` em paralelo:

```
HORA      CPU (target 50%)   RÉPLICAS
20:21:45  2%                 1   <- antes da carga
20:22:10  326%               1   <- HPA detectou o pico
20:22:23  326%               4   <- escalou
20:22:35  336%               5   <- atingiu o máximo (maxReplicas)
20:22:48–20:24:55  121%–225% 5   <- sustenta o máximo sob carga contínua
20:25:32  2%                 5   <- carga parou, CPU já caiu...
20:30:05  2%                 1   <- ...mas só desce depois da janela de
                                     estabilização padrão do HPA (~5min)
```

k6 reportou 272.775 requisições em 3 minutos (~1514 req/s), com a maior
parte das falhas concentrada bem no início, antes do HPA reagir. O
comportamento nas duas direções (escala pra cima rápido, escala pra baixo
devagar de propósito, para não oscilar) é o esperado de um HPA padrão.

Para reproduzir: `make load-test` num terminal, `kubectl get hpa -n mural
-w` em outro.

## Decisões e por quê

### Docker: imagem da API

Multi-stage build (`app/docker/api.Dockerfile`): builder em
`golang:1.23-alpine` compila um binário estático
(`CGO_ENABLED=0`, `-ldflags="-s -w"`), a imagem final é `scratch` — sem
shell, sem package manager, só o binário. Não precisa de CA certs porque a
conexão com o Postgres dentro do cluster usa `sslmode=disable` (tráfego
interno). Roda como usuário não-root (`65532:65532`).

**Tamanho medido:**

| Imagem | Tamanho |
|---|---|
| `golang:1.23-alpine` (como a app rodava via `go run` no compose) | 246 MB |
| `mural-api:local` (multi-stage, `scratch`) | **9.38 MB** |

Redução de ~26x. O front (`app/docker/web.Dockerfile`) é só `nginx:1.27-alpine`
mais os estáticos — já é mínimo por natureza (48.3 MB, igual à imagem base).

### Helm: hook de migração é `post-install,post-upgrade`, não `pre-install`

A primeira tentativa usou `pre-install,pre-upgrade` (a associação mais óbvia
com "roda antes da API"). Falhou: hooks `pre-install` rodam **antes de
qualquer manifesto normal do release**, incluindo o `StatefulSet` do
Postgres — então o Job de migração não tinha banco nenhum pra esperar (a
migração ficava presa no loop de espera até estourar o timeout).

A correção foi trocar para `post-install,post-upgrade`: Postgres, API e web
sobem juntos como recursos normais; o Job roda logo em seguida, espera o
Postgres aceitar conexão e aplica o schema. Nesse intervalo a API já está no
ar mas `/readyz` responde 503 (não toca no banco até a tabela existir) — é
exatamente a fricção que a `readinessProbe` existe pra segurar, sem tirar a
API do ar (a `livenessProbe`, em `/healthz`, nunca falha nesse meio tempo).

### Terraform: `helm_release` do chart usa `wait = false`

Combinar hook `post-install` com `wait = true` no Helm cria um deadlock real
(reproduzido manualmente durante o desenvolvimento): `--wait` espera os
recursos normais — incluindo o Deployment da API — ficarem `Ready` **antes**
de disparar os hooks `post-install`. Mas a API só fica `Ready` **depois** que
o hook migra o schema. Resultado: o Helm trava esperando algo que nunca vai
acontecer, porque o próprio `--wait` está impedindo o hook de rodar.

A solução: `helm_release.mural` usa `wait = false` (os hooks continuam
rodando de forma síncrona — isso o Helm sempre garante, com ou sem
`--wait`), e um `null_resource.wait_for_app` separado confirma, via `curl`
retry real através do Ingress, que a app está respondendo antes do
`terraform apply` ser considerado concluído.

### Terraform: namespace via provider `kubernetes`, não `create_namespace` do Helm

O namespace `mural` é criado por um `kubernetes_namespace` explícito, não
pela flag `create_namespace` do `helm_release`. Lifecycle e ownership ficam
claros no state do Terraform (e os três providers pedidos — `kind`, `helm`
e `kubernetes` — são todos efetivamente usados para provisionar recursos,
não só declarados).

### Terraform: `node_image` do kind pinado por digest

O provider `tehcyx/kind` embute uma versão da lib `sigs.k8s.io/kind` mais
nova que o `kind` CLI usado durante o desenvolvimento. Nesse ambiente (WSL2
rodando cgroups em modo híbrido v1/v2), a versão mais nova resolve a tag
`v1.31.0` para uma imagem cujo kubelet se recusa a inicializar
(`kubelet is configured to not run on a host using cgroup v1`), enquanto o
`kind` CLI local resolve a mesma tag para outro digest que funciona
normalmente. A correção foi fixar `node_image` no `kind_cluster` com o
digest exato já validado — o que também é, por si só, uma prática melhor de
IaC (evita "tag drift" entre applies).

### Segredo do banco

`postgres.password` não tem valor literal em nenhum arquivo versionado
(`values.yaml` traz só `""`). O Terraform gera a senha com
`random_password` e injeta via `set_sensitive` no `helm_release` — nunca
escrita em disco em texto plano, nunca aparece em `git diff`. Fica estável
entre applies (enquanto o state local persistir), o que é o que garante
"apply 2x = 0 changes" para o Secret.

### Ambiente de desenvolvimento (nota lateral, não faz parte da entrega)

Todo o desenvolvimento/teste local rodou dentro de um container "toolbox"
descartável (fora deste repositório, em `../toolbox/`) com `kind`,
`kubectl`, `helm`, `terraform` e o CLI do `docker`, falando com o Docker
Engine do host via `docker.sock` montado (Docker-out-of-Docker). Isso evitou
instalar essas ferramentas diretamente na máquina de desenvolvimento. É
irrelevante para a avaliação: quem roda `terraform apply` a partir deste
fork só precisa das "Ferramentas sugeridas" normais instaladas.

## Estrutura

```
app/docker/api.Dockerfile   # multi-stage, scratch
app/docker/web.Dockerfile   # nginx + proxy /api parametrizável
infra/helm/mural/           # chart: api, web, postgres (StatefulSet+PVC),
                             # secret, configmap, migrate-job (hook), ingress, hpa
infra/terraform/            # maestro: kind + traefik + metrics-server + helm_release do chart
scripts/load-test.js        # bônus: script k6 pro teste de carga do HPA
Makefile                    # atalhos (compose, terraform, lint, load-test)
```
