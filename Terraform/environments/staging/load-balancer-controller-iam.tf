# AWS Load Balancer Controller staging IAM permissions.
# AWS permissions are provided through EKS Pod Identity, not IRSA/OIDC.

data "aws_iam_policy_document" "load_balancer_controller_trust" {
  statement {
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
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["kube-system"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name        = "streamingapp-capstone-staging-load-balancer-controller"
  description = "Pod Identity role for the AWS Load Balancer Controller in staging."

  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_trust.json

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    Service     = "aws-load-balancer-controller"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "streamingapp-capstone-staging-load-balancer-controller"
  description = "AWS Load Balancer Controller v2.14.1 IAM policy."

  policy = file(
    "${path.module}/policies/aws-load-balancer-controller-v2.14.1.json"
  )

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    Service     = "aws-load-balancer-controller"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

output "load_balancer_controller_role_arn" {
  description = "EKS Pod Identity role ARN for the staging AWS Load Balancer Controller."
  value       = aws_iam_role.load_balancer_controller.arn
}


resource "aws_eks_pod_identity_association" "load_balancer_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.load_balancer_controller.arn
}