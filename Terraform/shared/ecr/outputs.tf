output "repository_urls" {
  description = "Image repository URLs keyed by service."
  value       = module.ecr.repository_urls
}

output "repository_arns" {
  description = "Image repository ARNs keyed by service."
  value       = module.ecr.repository_arns
}

output "repository_names" {
  description = "Image repository names keyed by service."
  value       = module.ecr.repository_names
}
