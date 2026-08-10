provider "kind" {}

# Cluster kind único: node de control-plane com o label que o Traefik precisa
# pra ser agendado como ingress ("ingress-ready=true") e as portas do host
# mapeadas para os NodePorts que o Traefik vai usar. Mesma configuração já
# validada manualmente antes de automatizar aqui.
resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true
  # Pinado por digest de propósito: a versão do provider (que embute uma
  # lib do kind mais nova que o kind CLI usado neste ambiente) resolve a tag
  # "v1.31.0" para uma imagem cujo kubelet se recusa a rodar em cgroup v1 —
  # este host (WSL2) roda em modo híbrido cgroup v1/v2. Este digest é o
  # mesmo que o kind CLI local usa e que já validei manualmente funcionando
  # neste host.
  node_image = "kindest/node:v1.31.0@sha256:53df588e04085fd41ae12de0c3fe4c72f7013bba32a20e7325357a1ac94ba865"

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      kubeadm_config_patches = [
        "kind: InitConfiguration\nnodeRegistration:\n  kubeletExtraArgs:\n    node-labels: \"ingress-ready=true\"\n"
      ]

      extra_port_mappings {
        container_port = 30080
        host_port      = var.http_host_port
      }
      extra_port_mappings {
        container_port = 30443
        host_port      = var.https_host_port
      }
    }
  }
}

# Credenciais dinâmicas (não um kubeconfig em arquivo): se o cluster for
# recriado, kubernetes/helm já apontam pro novo automaticamente.
provider "kubernetes" {
  host                   = kind_cluster.this.endpoint
  client_certificate     = kind_cluster.this.client_certificate
  client_key             = kind_cluster.this.client_key
  cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.this.endpoint
    client_certificate     = kind_cluster.this.client_certificate
    client_key             = kind_cluster.this.client_key
    cluster_ca_certificate = kind_cluster.this.cluster_ca_certificate
  }
}

# Nunca versionado: gerada pelo Terraform, injetada no chart via
# set_sensitive, nunca escrita em disco em texto plano. Fica estável entre
# applies enquanto o state local persistir — é isso que garante "apply 2x =
# 0 changes" para o Secret do banco.
resource "random_password" "db" {
  length  = 24
  special = false
}

locals {
  api_dir        = "${path.module}/../../app/api"
  web_dir        = "${path.module}/../../app/web"
  api_dockerfile = "${path.module}/../../app/docker/api.Dockerfile"
  web_dockerfile = "${path.module}/../../app/docker/web.Dockerfile"

  api_image = "${var.api_image_repository}:${var.image_tag}"
  web_image = "${var.web_image_repository}:${var.image_tag}"

  # Hash agregado do código-fonte: só reconstrói a imagem quando o conteúdo
  # realmente muda, o que garante 0 diff num segundo apply sem alterações.
  api_src_hash = sha256(join("", [
    for f in fileset(local.api_dir, "**") : filesha256("${local.api_dir}/${f}")
  ]))
  web_src_hash = sha256(join("", [
    for f in fileset(local.web_dir, "**") : filesha256("${local.web_dir}/${f}")
  ]))
}

resource "null_resource" "build_api_image" {
  triggers = {
    dockerfile_hash = filesha256(local.api_dockerfile)
    src_hash        = local.api_src_hash
    image           = local.api_image
  }

  provisioner "local-exec" {
    command = "docker build -t ${local.api_image} -f ${local.api_dockerfile} ${local.api_dir}"
  }
}

resource "null_resource" "build_web_image" {
  triggers = {
    dockerfile_hash = filesha256(local.web_dockerfile)
    src_hash = sha256(join("", [
      for f in fileset(local.web_dir, "**") : filesha256("${local.web_dir}/${f}")
    ]))
    image = local.web_image
  }

  provisioner "local-exec" {
    command = "docker build -t ${local.web_image} -f ${local.web_dockerfile} ${local.web_dir}"
  }
}

# "kind load docker-image": disponibiliza a imagem já construída localmente
# dentro do cluster, sem precisar de um registry.
resource "null_resource" "load_api_image" {
  triggers = {
    build_id   = null_resource.build_api_image.id
    cluster_id = kind_cluster.this.id
  }
  depends_on = [kind_cluster.this, null_resource.build_api_image]

  provisioner "local-exec" {
    command = "kind load docker-image ${local.api_image} --name ${var.cluster_name}"
  }
}

resource "null_resource" "load_web_image" {
  triggers = {
    build_id   = null_resource.build_web_image.id
    cluster_id = kind_cluster.this.id
  }
  depends_on = [kind_cluster.this, null_resource.build_web_image]

  provisioner "local-exec" {
    command = "kind load docker-image ${local.web_image} --name ${var.cluster_name}"
  }
}

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true

  # service.type (no root dos values) não existe no chart: o campo real é
  # service.spec.type — usar o nome errado instala como LoadBalancer (o
  # default) e trava esperando um external-IP que o kind nunca dá.
  set {
    name  = "service.spec.type"
    value = "NodePort"
  }
  set {
    name  = "ports.web.nodePort"
    value = "30080"
  }
  set {
    name  = "ports.websecure.nodePort"
    value = "30443"
  }

  depends_on = [kind_cluster.this]
}

# Necessário pro HPA (bônus): sem metrics-server não existe fonte de
# métricas de CPU/memória no cluster e o HPA fica com <unknown> pra sempre.
resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = var.metrics_server_chart_version
  namespace        = "kube-system"
  create_namespace = true

  # kind não expõe um certificado de kubelet que o metrics-server valide por
  # padrão — --kubelet-insecure-tls é o ajuste padrão pra clusters locais.
  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }
  set {
    name  = "args[1]"
    value = "--kubelet-preferred-address-types=InternalIP"
  }

  depends_on = [kind_cluster.this]
}

# Namespace criado explicitamente via provider kubernetes (não via
# create_namespace do helm_release): lifecycle e ownership ficam claros no
# state do Terraform, em vez de implícitos numa flag do release do Helm.
resource "kubernetes_namespace" "mural" {
  metadata {
    name = var.namespace
  }

  depends_on = [kind_cluster.this]
}

resource "helm_release" "mural" {
  name      = "mural"
  chart     = "${path.module}/../helm/mural"
  namespace = kubernetes_namespace.mural.metadata[0].name

  # O Job de migração é um hook post-install/post-upgrade (veja
  # migrate-job.yaml): um hook pre-install rodaria antes do StatefulSet do
  # Postgres existir, e um post-install combinado com wait=true trava, porque
  # o Helm espera a API ficar Ready ANTES de disparar hooks post-install —
  # e a API só fica Ready DEPOIS que o hook migra o schema (deadlock real,
  # confirmado manualmente). Por isso wait=false aqui: os hooks continuam
  # rodando de forma síncrona (isso o Helm sempre garante, com ou sem
  # --wait); quem confirma que a app está respondendo de fato é o
  # null_resource.wait_for_app logo abaixo, via HTTP real através do
  # Ingress.
  wait = false

  set {
    name  = "image.api.repository"
    value = var.api_image_repository
  }
  set {
    name  = "image.api.tag"
    value = var.image_tag
  }
  set {
    name  = "image.web.repository"
    value = var.web_image_repository
  }
  set {
    name  = "image.web.tag"
    value = var.image_tag
  }
  set {
    name  = "ingress.host"
    value = var.ingress_host
  }
  set {
    name  = "postgres.storage"
    value = var.postgres_storage
  }
  set_sensitive {
    name  = "postgres.password"
    value = random_password.db.result
  }
  set {
    name  = "autoscaling.enabled"
    value = var.autoscaling_enabled
  }
  set {
    name  = "autoscaling.minReplicas"
    value = var.autoscaling_min_replicas
  }
  set {
    name  = "autoscaling.maxReplicas"
    value = var.autoscaling_max_replicas
  }
  set {
    name  = "autoscaling.targetCPUUtilizationPercentage"
    value = var.autoscaling_target_cpu
  }

  depends_on = [
    null_resource.load_api_image,
    null_resource.load_web_image,
    helm_release.traefik,
    helm_release.metrics_server,
  ]
}

# Verificação real de "app no ar", desacoplada do wait=false acima: espera
# até a API responder via Ingress antes de considerar o apply concluído.
resource "null_resource" "wait_for_app" {
  triggers = {
    release = helm_release.mural.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "aguardando o Mural responder em http://${var.ingress_host}/ ..."
      for i in $(seq 1 60); do
        if curl -sf -o /dev/null "http://${var.ingress_host}/api/messages"; then
          echo "Mural respondendo."
          exit 0
        fi
        sleep 3
      done
      echo "Mural não respondeu a tempo." >&2
      exit 1
    EOT
  }

  depends_on = [helm_release.mural]
}
