# Staging application S3 workload identity.
# Mirrors the develop workload permissions but scopes trust and names to staging.

locals {
  application_namespace = "streaming-app-staging"

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
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.application_namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

resource "aws_iam_role" "media_workload" {
  for_each = local.media_workloads

  name               = "streamingapp-capstone-staging-${each.key}-media"
  description        = "Staging S3 media access for the ${each.key} service through EKS Pod Identity."
  assume_role_policy = data.aws_iam_policy_document.media_workload_trust[each.key].json

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    Service     = each.key
    ManagedBy   = "Terraform"
    Purpose     = "Application S3 access through EKS Pod Identity"
  }
}

data "aws_iam_policy_document" "media_workload_permissions" {
  for_each = local.media_workloads

  statement {
    sid     = "ServiceMediaAccess"
    effect  = "Allow"
    actions = each.value.actions

    resources = [
      "${aws_s3_bucket.media.arn}/videos/*",
      "${aws_s3_bucket.media.arn}/thumbnails/*",
    ]
  }
}

resource "aws_iam_role_policy" "media_workload" {
  for_each = local.media_workloads

  name   = "media-object-access"
  role   = aws_iam_role.media_workload[each.key].id
  policy = data.aws_iam_policy_document.media_workload_permissions[each.key].json
}

resource "aws_eks_pod_identity_association" "media_workload" {
  for_each = local.media_workloads

  cluster_name    = module.eks.cluster_name
  namespace       = local.application_namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.media_workload[each.key].arn
}


output "media_workload_role_arns" {
  description = "Staging IAM role ARNs used by application workloads."
  value = {
    for service, role in aws_iam_role.media_workload :
    service => role.arn
  }
}
