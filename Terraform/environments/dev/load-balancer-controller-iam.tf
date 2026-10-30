data "aws_iam_policy_document" "load_balancer_controller_trust" {
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
        "system:serviceaccount:kube-system:aws-load-balancer-controller"
      ]
    }
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name        = "streamingapp-capstone-dev-load-balancer-controller"
  description = "IRSA role for the AWS Load Balancer Controller."

  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_trust.json

  tags = {
    Service = "aws-load-balancer-controller"
  }
}

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "streamingapp-capstone-dev-load-balancer-controller"
  description = "AWS Load Balancer Controller v2.14.1 official IAM policy."

  policy = file(
    "${path.module}/policies/aws-load-balancer-controller-v2.14.1.json"
  )

  tags = {
    Service = "aws-load-balancer-controller"
  }
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

output "load_balancer_controller_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller."
  value       = aws_iam_role.load_balancer_controller.arn
}