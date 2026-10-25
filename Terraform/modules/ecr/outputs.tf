output "repository_urls" {
  description = "Repository URLs keyed by the application service."
  value = {
    for service, repository in aws_ecr_repository.this :
    service => repository.repository_url
  }
}

output "repository_arns" {
  description = "Repository ARNs for scoping IAM permissions."
  value = {
    for service, repository in aws_ecr_repository.this :
    service => repository.arn
  }
}

output "repository_names" {
  description = "Repository names keyed by the application service."
  value = {
    for service, repository in aws_ecr_repository.this :
    service => repository.name
  }
}