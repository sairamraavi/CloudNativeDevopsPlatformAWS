
data "aws_partition" "current" {}

locals {
  application_identity_tags = local.common_tags

  application_s3_object_arns = [
    "${module.application_storage.bucket_arn}/videos/*",
    "${module.application_storage.bucket_arn}/thumbnails/*"
  ]
}

# Trust policy shared by the application workload IAM roles.
data "aws_iam_policy_document" "application_pod_trust" {
  statement {
    sid    = "AllowEKSWorkloadIdentity"
    effect = "Allow"

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.expected_account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [module.eks.cluster_arn]
    }
  }
}

# Admin service: upload, read and delete application media.
resource "aws_iam_role" "admin_s3" {
  name               = "${local.name_prefix}-admin-s3"
  description        = "EKS Admin workload access to application video and thumbnail objects."
  assume_role_policy = data.aws_iam_policy_document.application_pod_trust.json
  tags               = local.application_identity_tags
}

data "aws_iam_policy_document" "admin_s3" {
  statement {
    sid    = "AdminMediaObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = local.application_s3_object_arns
  }
}

resource "aws_iam_role_policy" "admin_s3" {
  name   = "${local.name_prefix}-admin-media-access"
  role   = aws_iam_role.admin_s3.id
  policy = data.aws_iam_policy_document.admin_s3.json
}

resource "aws_eks_pod_identity_association" "admin_s3" {
  cluster_name    = module.eks.cluster_name
  namespace       = "streamingapp"
  service_account = "streamingapp-admin-s3"
  role_arn        = aws_iam_role.admin_s3.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy.admin_s3
  ]
}

# Streaming service: read-only access to application media.
resource "aws_iam_role" "streaming_s3" {
  name               = "${local.name_prefix}-streaming-s3"
  description        = "EKS Streaming workload read-only access to application media."
  assume_role_policy = data.aws_iam_policy_document.application_pod_trust.json
  tags               = local.application_identity_tags
}

data "aws_iam_policy_document" "streaming_s3" {
  statement {
    sid    = "StreamingMediaReadOnly"
    effect = "Allow"

    actions = [
      "s3:GetObject"
    ]

    resources = local.application_s3_object_arns
  }
}

resource "aws_iam_role_policy" "streaming_s3" {
  name   = "${local.name_prefix}-streaming-media-read"
  role   = aws_iam_role.streaming_s3.id
  policy = data.aws_iam_policy_document.streaming_s3.json
}

resource "aws_eks_pod_identity_association" "streaming_s3" {
  cluster_name    = module.eks.cluster_name
  namespace       = "streamingapp"
  service_account = "streamingapp-streaming-s3"
  role_arn        = aws_iam_role.streaming_s3.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy.streaming_s3
  ]
}

output "admin_s3_role_arn" {
  description = "IAM role associated with the Admin S3 ServiceAccount."
  value       = aws_iam_role.admin_s3.arn
}

output "streaming_s3_role_arn" {
  description = "IAM role associated with the Streaming S3 ServiceAccount."
  value       = aws_iam_role.streaming_s3.arn
}
