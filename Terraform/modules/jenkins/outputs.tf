output "instance_id" {
  description = "Jenkins EC2 instance ID."
  value       = aws_instance.jenkins.id
}

output "private_ip" {
  description = "Private IP address of the Jenkins EC2 instance."
  value       = aws_instance.jenkins.private_ip
}

output "iam_role_arn" {
  description = "IAM role ARN used by Jenkins and registered with EKS."
  value       = aws_iam_role.jenkins.arn
}

output "security_group_id" {
  description = "Jenkins EC2 security group ID."
  value       = aws_security_group.jenkins.id
}

output "instance_profile_name" {
  description = "Jenkins EC2 instance profile name."
  value       = aws_iam_instance_profile.jenkins.name
}
