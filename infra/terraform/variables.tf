variable "cluster_name" {
  description = "Nome do cluster kind."
  type        = string
  default     = "mural"
}

variable "namespace" {
  description = "Namespace onde o chart do Mural é instalado."
  type        = string
  default     = "mural"
}

variable "ingress_host" {
  description = "Host pelo qual o Mural é acessado (resolve para 127.0.0.1 via *.localtest.me)."
  type        = string
  default     = "mural.localtest.me"
}

variable "http_host_port" {
  description = "Porta do host mapeada pelo kind para o Traefik (HTTP)."
  type        = number
  default     = 80
}

variable "https_host_port" {
  description = "Porta do host mapeada pelo kind para o Traefik (HTTPS)."
  type        = number
  default     = 443
}

variable "api_image_repository" {
  type    = string
  default = "mural-api"
}

variable "web_image_repository" {
  type    = string
  default = "mural-web"
}

variable "image_tag" {
  description = "Tag usada para as imagens da API e do front (a mesma para as duas, buildadas localmente)."
  type        = string
  default     = "local"
}

variable "postgres_storage" {
  type    = string
  default = "1Gi"
}

variable "traefik_chart_version" {
  description = "Versão do chart oficial do Traefik (mesma testada manualmente)."
  type        = string
  default     = "41.2.0"
}

variable "metrics_server_chart_version" {
  description = "Versão do chart oficial do metrics-server (necessário pro HPA ter métricas de CPU)."
  type        = string
  default     = "3.13.1"
}

variable "autoscaling_enabled" {
  description = "Liga o HPA da API (bônus)."
  type        = bool
  default     = true
}

variable "autoscaling_min_replicas" {
  type    = number
  default = 1
}

variable "autoscaling_max_replicas" {
  type    = number
  default = 5
}

variable "autoscaling_target_cpu" {
  description = "Percentual de utilização de CPU (sobre o request) que o HPA mira."
  type        = number
  default     = 50
}
