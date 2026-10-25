output "vpc_id" {
  description = "Dedicated project VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Project VPC IPv4 CIDR."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs in the supplied AZ order."
  value = [
    for zone in var.availability_zones :
    aws_subnet.public[zone].id
  ]
}

output "private_subnet_ids" {
  description = "Private subnet IDs in the supplied AZ order."
  value = [
    for zone in var.availability_zones :
    aws_subnet.private[zone].id
  ]
}

output "public_route_table_id" {
  description = "Shared public subnet route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private route table IDs in the supplied AZ order."
  value = [
    for zone in var.availability_zones :
    aws_route_table.private[zone].id
  ]
}

output "nat_gateway_ids" {
  description = "Zonal NAT gateway IDs keyed by Availability Zone."
  value = {
    for zone, gateway in aws_nat_gateway.this :
    zone => gateway.id
  }
}

output "nat_public_ips" {
  description = "Outbound public IPs, usable for external database allowlists."
  value = {
    for zone, address in aws_eip.nat :
    zone => address.public_ip
  }
}