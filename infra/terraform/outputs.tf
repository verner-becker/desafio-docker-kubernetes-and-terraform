output "mural_url" {
  description = "URL do Mural de Recados (abra no navegador)."
  value       = "http://${var.ingress_host}"
}

output "cluster_name" {
  value = kind_cluster.this.name
}

output "namespace" {
  value = var.namespace
}
