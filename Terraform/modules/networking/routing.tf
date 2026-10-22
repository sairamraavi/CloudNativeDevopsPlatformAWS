locals {
  nat_zones = {
    for zone, index in local.zones :
    zone => index
    if var.nat_mode == "per_az" || (
      var.nat_mode == "single" && index == 0
    )
  }

  private_egress_zones = {
    for zone, index in local.zones :
    zone => index
    if var.nat_mode != "none"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = local.zones

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  for_each = local.nat_zones

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-${each.key}"
  })
}

resource "aws_nat_gateway" "this" {
  for_each = local.nat_zones

  allocation_id     = aws_eip.nat[each.key].id
  subnet_id         = aws_subnet.public[each.key].id
  connectivity_type = "public"

  depends_on = [
    aws_route.public_internet,
    aws_route_table_association.public
  ]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-${each.key}"
  })
}

resource "aws_route_table" "private" {
  for_each = local.zones

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${each.key}"
  })
}

resource "aws_route_table_association" "private" {
  for_each = local.zones

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_route" "private_internet" {
  for_each = local.private_egress_zones

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"

  nat_gateway_id = aws_nat_gateway.this[
    var.nat_mode == "single" ? var.availability_zones[0] : each.key
  ].id
}