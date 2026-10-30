resource "aws_security_group" "jenkins" {
  name_prefix = "${var.name_prefix}-jenkins-"
  description = "Jenkins controller with no inbound network access; administration uses SSM."
  vpc_id      = var.vpc_id

  # No ingress rules. Use Systems Manager Session Manager.
  egress {
    description = "Outbound access through the private subnet NAT route."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-jenkins"
  })

  lifecycle {
    create_before_destroy = true
  }
}
