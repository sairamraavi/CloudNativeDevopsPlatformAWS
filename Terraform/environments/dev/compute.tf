variable "node_instance_types" {
  description = "EC2 instance types for EKS managed worker nodes."
  type        = list(string)
  default     = ["t3.large"]
}
