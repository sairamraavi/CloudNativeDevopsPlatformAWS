data "aws_iam_role" "jenkins" {
  name = "streamingapp-capstone-dev-jenkins"
}

data "aws_instance" "jenkins" {
  filter {
    name   = "tag:Name"
    values = ["streamingapp-capstone-dev-jenkins"]
  }
  filter {
    name   = "instance-state-name"
    values = ["running"]
  }
}

resource "aws_iam_role_policy" "jenkins_staging" {
  role = data.aws_iam_role.jenkins.name
  name = "describe-staging-eks"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = "arn:aws:eks:${var.aws_region}:${var.expected_account_id}:cluster/${module.eks.cluster_name}"
    }]
  })
}

resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = data.aws_iam_role.jenkins.arn
}

resource "aws_eks_access_policy_association" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.jenkins.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  access_scope {
    type       = "namespace"
    namespaces = [local.application_namespace]
  }
}
