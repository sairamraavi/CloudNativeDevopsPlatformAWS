
data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["external-secrets"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "streamingapp-capstone-staging-external-secrets"
  description        = "External Secrets Operator Pod Identity role."
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    ManagedBy   = "Terraform"
    Purpose     = "External Secrets Operator Pod Identity"
  }
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ReadStagingApplicationSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [
      aws_secretsmanager_secret.application.arn,
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-staging-application-secret"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}
