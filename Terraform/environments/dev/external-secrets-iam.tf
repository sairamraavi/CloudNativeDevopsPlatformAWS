variable "application_secret_arn" {
  description = "Exact ARN of the persistent dev application secret."
  type        = string

  validation {
    condition = can(regex(
      "^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$",
      var.application_secret_arn
    ))
    error_message = "Provide the complete Secrets Manager secret ARN."
  }
}

data "aws_iam_policy_document" "secret_reader_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.application_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.application_oidc_host}:sub"
      values = [
        "system:serviceaccount:${local.application_namespace}:streamingapp-secret-reader"
      ]
    }
  }
}

resource "aws_iam_role" "secret_reader" {
  name               = "streamingapp-capstone-dev-secret-reader"
  description        = "Read the dev application secret through IRSA."
  assume_role_policy = data.aws_iam_policy_document.secret_reader_trust.json

  tags = {
    Service = "external-secrets"
  }
}

data "aws_iam_policy_document" "secret_reader_permissions" {
  statement {
    sid    = "ReadApplicationSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [var.application_secret_arn]
  }
}

resource "aws_iam_role_policy" "secret_reader" {
  name   = "read-application-secret"
  role   = aws_iam_role.secret_reader.id
  policy = data.aws_iam_policy_document.secret_reader_permissions.json
}

output "secret_reader_role_arn" {
  description = "Role ARN for the application secret-reader service account."
  value       = aws_iam_role.secret_reader.arn
}