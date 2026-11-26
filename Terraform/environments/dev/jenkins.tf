variable "jenkins_public_key_path" {
  description = "Path to the Jenkins SSH public key on the Terraform workstation."
  type        = string
}

variable "jenkins_admin_cidr" {
  description = "Administrator public IPv4 address with /32."
  type        = string

  validation {
    condition = (
      can(cidrnetmask(var.jenkins_admin_cidr)) &&
      endswith(var.jenkins_admin_cidr, "/32")
    )
    error_message = "Provide a valid IPv4 /32 CIDR."
  }
}

variable "jenkins_ami_id" {
  description = "Verified Ubuntu 24.04 amd64 AMI ID for this region."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.jenkins_ami_id))
    error_message = "Provide a valid AMI ID."
  }
}

resource "aws_key_pair" "jenkins" {
  key_name   = "streamingapp-capstone-dev-jenkins"
  public_key = file(pathexpand(var.jenkins_public_key_path))
}

resource "aws_security_group" "jenkins" {
  name        = "streamingapp-capstone-dev-jenkins"
  description = "Jenkins host access"
  vpc_id      = module.networking.vpc_id

  tags = {
    Name = "streamingapp-capstone-dev-jenkins"
  }
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_ssh" {
  security_group_id = aws_security_group.jenkins.id
  description       = "SSH from administrator workstation"
  cidr_ipv4         = var.jenkins_admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "jenkins_outbound" {
  security_group_id = aws_security_group.jenkins.id
  description       = "Package downloads and project service connections"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_iam_role" "jenkins" {
  name = "streamingapp-capstone-dev-jenkins"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "streamingapp-capstone-dev-jenkins"
  role = aws_iam_role.jenkins.name
}

resource "aws_instance" "jenkins" {
  ami                         = var.jenkins_ami_id
  instance_type               = "t3.large"
  subnet_id                   = module.networking.public_subnet_ids[0]
  associate_public_ip_address = true

  key_name               = aws_key_pair.jenkins.key_name
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 40
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name        = "streamingapp-capstone-dev-jenkins-root"
      Project     = "streamingapp-capstone"
      Environment = "dev"
      ManagedBy   = "Terraform"
    }
  }

  tags = {
    Name = "streamingapp-capstone-dev-jenkins"
  }

  depends_on = [
    aws_iam_role_policy_attachment.jenkins_ssm,
    module.networking
  ]
}

output "jenkins_instance_id" {
  value = aws_instance.jenkins.id
}

output "jenkins_public_ip" {
  value = aws_instance.jenkins.public_ip
}

output "jenkins_private_ip" {
  value = aws_instance.jenkins.private_ip
}

output "jenkins_role_arn" {
  value = aws_iam_role.jenkins.arn
}