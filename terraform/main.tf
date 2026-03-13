terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "fiapx-tfstate"
    key    = "fiapx/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------
# VPC  (2 AZs apenas para reduzir custo de NAT Gateway)
# ------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.2"

  name = "fiapx-${var.environment}"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  # 1 unico NAT Gateway (single_nat_gateway) economiza ~$33/mes por AZ removida
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/fiapx-${var.environment}" = "shared"
    "kubernetes.io/role/elb"                          = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/fiapx-${var.environment}" = "shared"
    "kubernetes.io/role/internal-elb"                = "1"
  }

  tags = local.common_tags
}

# VPC Endpoints - elimina trafego pago via NAT Gateway para S3 e ECR
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
  tags              = merge(local.common_tags, { Name = "fiapx-s3-endpoint" })
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags                = merge(local.common_tags, { Name = "fiapx-ecr-api-endpoint" })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags                = merge(local.common_tags, { Name = "fiapx-ecr-dkr-endpoint" })
}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "fiapx-vpc-endpoints-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  tags = local.common_tags
}

# ------------------------------------------------------------
# EKS  (1 node t3.small - suficiente para carga academica)
# ------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

  cluster_name    = "fiapx-${var.environment}"
  cluster_version = "1.29"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # Addons essenciais (todos open-source / sem custo adicional de licenca)
  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }

  eks_managed_node_groups = {
    main = {
      name           = "fiapx-main"
      instance_types = ["t3.small"]   # 2 vCPU, 2 GB RAM - menor viavel para .NET 8

      min_size     = 1
      max_size     = 5   # HPA pode subir ate 5 nodes
      desired_size = 2   # 2 nodes iniciais para distribuir 4 servicos

      disk_size = 20

      labels = {
        environment = var.environment
        project     = "fiapx"
      }

      tags = local.common_tags
    }
  }

  tags = local.common_tags
}

# ------------------------------------------------------------
# S3  (vídeos e ZIPs - servico gerenciado mais barato que MinIO no EKS)
# ------------------------------------------------------------
resource "aws_s3_bucket" "videos" {
  bucket        = "fiapx-videos-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.environment != "prod"
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "videos" {
  bucket = aws_s3_bucket.videos.id
  versioning_configuration { status = "Disabled" } # desabilitado para reduzir custo
}

resource "aws_s3_bucket_server_side_encryption_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_cors_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}

# Lifecycle: remove arquivos temporários após 7 dias
resource "aws_s3_bucket_lifecycle_configuration" "videos" {
  bucket = aws_s3_bucket.videos.id
  rule {
    id     = "expire-temp"
    status = "Enabled"
    filter { prefix = "tmp/" }
    expiration { days = 7 }
  }
}

# ------------------------------------------------------------
# ECR  (4 repositórios - sem custo por armazenamento < 500 MB)
# ------------------------------------------------------------
resource "aws_ecr_repository" "services" {
  for_each             = toset(["auth-service", "upload-service", "processor-service", "frontend"])
  name                 = "fiapx/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = false } # desabilitado para reduzir latencia

  tags = local.common_tags
}

# Lifecycle: manter apenas as 5 ultimas imagens por repositorio
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Manter apenas 5 imagens"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------------
# IAM  (role para pods acessarem S3)
# ------------------------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "pod_s3" {
  name = "fiapx-pod-s3-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:fiapx:fiapx-upload"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "pod_s3" {
  name = "s3-access"
  role = aws_iam_role.pod_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.videos.arn, "${aws_s3_bucket.videos.arn}/*"]
    }]
  })
}

# ------------------------------------------------------------
# Locals
# ------------------------------------------------------------
locals {
  common_tags = {
    Project     = "fiapx"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
