resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "${local.name_prefix}-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "${local.name_prefix}-public-b"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "${local.name_prefix}-private-a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "${local.name_prefix}-private-b"
  }
}

resource "aws_eip" "nat_a" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-eip-nat-a"
  }
}

resource "aws_eip" "nat_b" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-eip-nat-b"
  }
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${local.name_prefix}-nat-a"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id

  tags = {
    Name = "${local.name_prefix}-nat-b"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-public"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.a.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-private-a"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.b.id
  }

  tags = {
    Name = "${local.name_prefix}-rt-private-b"
  }
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_a.id, aws_route_table.private_b.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGetPutOnImagesBucketOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:PutObject"]
        Resource  = "arn:aws:s3:::${local.bucket_name}/*"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-vpce-s3"
  }
}

resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  private_dns_enabled = true
  security_group_ids  = [aws_security_group.vpce_sqs.id]

  tags = {
    Name = "${local.name_prefix}-vpce-sqs"
  }
}

resource "aws_security_group" "upload_lambda" {
  name        = "${local.name_prefix}-upload-lambda-sg"
  description = "Security group de la upload-lambda"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-upload-lambda-sg"
  }
}

resource "aws_security_group" "crop_lambda" {
  name        = "${local.name_prefix}-crop-lambda-sg"
  description = "Security group de la crop-lambda"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-crop-lambda-sg"
  }
}

resource "aws_security_group" "vpce_sqs" {
  name        = "${local.name_prefix}-vpce-sqs-sg"
  description = "Security group del endpoint de SQS"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-vpce-sqs-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "upload_to_s3" {
  security_group_id = aws_security_group.upload_lambda.id
  description       = "HTTPS hacia S3 por el Gateway Endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id

  tags = {
    Name = "${local.name_prefix}-upload-to-s3"
  }
}

resource "aws_vpc_security_group_egress_rule" "upload_to_sqs" {
  security_group_id            = aws_security_group.upload_lambda.id
  description                  = "HTTPS hacia el endpoint de SQS"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpce_sqs.id

  tags = {
    Name = "${local.name_prefix}-upload-to-sqs"
  }
}

resource "aws_vpc_security_group_egress_rule" "crop_to_s3" {
  security_group_id = aws_security_group.crop_lambda.id
  description       = "HTTPS hacia S3 por el Gateway Endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id

  tags = {
    Name = "${local.name_prefix}-crop-to-s3"
  }
}

resource "aws_vpc_security_group_egress_rule" "crop_to_sqs" {
  security_group_id            = aws_security_group.crop_lambda.id
  description                  = "HTTPS hacia el endpoint de SQS"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpce_sqs.id

  tags = {
    Name = "${local.name_prefix}-crop-to-sqs"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_sqs_from_upload" {
  security_group_id            = aws_security_group.vpce_sqs.id
  description                  = "HTTPS desde la upload-lambda"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.upload_lambda.id

  tags = {
    Name = "${local.name_prefix}-vpce-sqs-from-upload"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_sqs_from_crop" {
  security_group_id            = aws_security_group.vpce_sqs.id
  description                  = "HTTPS desde la crop-lambda"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.crop_lambda.id

  tags = {
    Name = "${local.name_prefix}-vpce-sqs-from-crop"
  }
}
