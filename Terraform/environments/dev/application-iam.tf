variable "media_bucket_arn" {
  description = "Persistent media bucket ARN supplied by the deployment operator."
  type        = string

  validation {
    condition = can(regex(
      "^arn:[^:]+:s3:::[a-z0-9][a-z0-9.-]+$",
      var.media_bucket_arn
    ))
    error_message = "Provide an S3 bucket ARN without an object path."
  }
}

locals {
  application_namespace = "streaming-app-dev"

  application_oidc_host = trimprefix(
    module.eks.cluster_oidc_issuer_url,
    "https://"
  )

  media_workloads = {
    admin = {
      service_account = "streamingapp-admin"
      actions         = ["s3:PutObject", "s3:DeleteObject"]
    }
    streaming = {
      service_account = "streamingapp-streaming"
      actions         = ["s3:GetObject"]
    }
  }
}

data "aws_iam_policy_document" "media_workload_trust" {
  for_each = local.media_workloads

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
        "system:serviceaccount:${local.application_namespace}:${each.value.service_account}"
      ]
    }
  }
}

resource "aws_iam_role" "media_workload" {
  for_each = local.media_workloads

  name               = "streamingapp-capstone-dev-${each.key}-media"
  description        = "S3 media access for the ${each.key} service."
  assume_role_policy = data.aws_iam_policy_document.media_workload_trust[each.key].json

  tags = {
    Service = each.key
  }
}

data "aws_iam_policy_document" "media_workload_permissions" {
  for_each = local.media_workloads

  statement {
    sid     = "ServiceMediaAccess"
    effect  = "Allow"
    actions = each.value.actions

    resources = [
      "${var.media_bucket_arn}/videos/*",
      "${var.media_bucket_arn}/thumbnails/*",
    ]
  }
}

resource "aws_iam_role_policy" "media_workload" {
  for_each = local.media_workloads

  name   = "media-object-access"
  role   = aws_iam_role.media_workload[each.key].id
  policy = data.aws_iam_policy_document.media_workload_permissions[each.key].json
}

output "media_workload_role_arns" {
  description = "IAM role ARNs to annotate on application service accounts."
  value = {
    for service, role in aws_iam_role.media_workload :
    service => role.arn
  }
}