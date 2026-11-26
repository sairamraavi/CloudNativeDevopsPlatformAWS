locals {
  jenkins_ecr_repository_arns = [
    for service in ["frontend", "auth", "streaming", "admin", "chat"] :
    "arn:aws:ecr:${var.aws_region}:${var.expected_account_id}:repository/streamingapp-capstone-${service}"
  ]
}

resource "aws_iam_role_policy" "jenkins_application_deployment" {
  name = "streamingapp-application-deployment"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AuthenticateToECR"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushAndInspectApplicationImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:DescribeImageScanFindings"
        ]
        Resource = local.jenkins_ecr_repository_arns
      },
      {
        Sid      = "DescribeProjectCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = "arn:aws:eks:${var.aws_region}:${var.expected_account_id}:cluster/${module.eks.cluster_name}"
      }
    ]
  })
}

resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_dev" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.jenkins.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["streaming-app-dev"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_to_eks_api" {
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.jenkins.id
  description                  = "Jenkins access to private EKS API"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}