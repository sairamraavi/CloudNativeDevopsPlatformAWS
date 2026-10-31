resource "aws_vpc_security_group_ingress_rule" "jenkins_metrics" {
  security_group_id            = aws_security_group.jenkins.id
  referenced_security_group_id = module.eks.cluster_security_group_id

  description = "Jenkins metrics from EKS nodes and pods"
  ip_protocol = "tcp"
  from_port   = 8082
  to_port     = 8082
}