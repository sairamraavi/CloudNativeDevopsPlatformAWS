
module "networking" {
  source = "../../modules/networking"

  name_prefix        = "streamingapp-capstone-staging"
  vpc_cidr           = "10.10.0.0/16"
  availability_zones = var.availability_zones

  # One NAT Gateway keeps staging costs lower than one per AZ.
  nat_mode = "single"

  tags = {
    Project     = "streamingapp-capstone"
    Environment = "staging"
    ManagedBy   = "Terraform"
  }
}
