variable "media_allowed_origins" {
  description = "Browser origins allowed to make signed request to s3"
  type        = list(string)
  default = [
    "http://localhost:3000",
    "https://streaming.sairamraavi.com",
  ]

  validation {
    condition = (
      length(var.media_allowed_origins) > 0 &&
      alltrue([
        for origin in var.media_allowed_origins :
        can(regex("^https?://[^/]+$", origin)) &&
        length(regexall("\\*", origin)) == 0
      ])
    )
    error_message = "Provide explicit HTTP(S) origins without paths or wildcards."
  }
}

resource "aws_s3_bucket" "media" {
  bucket_prefix = "streamingapp-media-"
  force_destroy = false

  tags = {
    Name    = "streamingapp-capstone-media"
    Purpose = "Application media storage"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "media_transport" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.media.arn,
      "${aws_s3_bucket.media.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:secureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = data.aws_iam_policy_document.media_transport.json

  depends_on = [
    aws_s3_bucket_public_access_block.media
  ]
}

resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_origins = var.media_allowed_origins
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 300
  }
}

output "media_bucket_name" {
  description = "Persistent private bucket for application media."
  value       = aws_s3_bucket.media.id
}

output "media_bucket_arn" {
  description = "Bucket ARN used to scope workload IAM policies."
  value       = aws_s3_bucket.media.arn
}