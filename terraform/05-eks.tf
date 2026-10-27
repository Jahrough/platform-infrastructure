module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.2.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  enable_irsa     = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  eks_managed_node_groups = {
    default = {
      min_size     = 2
      max_size     = 3
      desired_size = 2

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      iam_role_additional_policies = {
        CloudWatchAgentServerPolicy = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      }
    }
  }

  cluster_addons = {
    eks-pod-identity-agent = {
      most_recent = true
    }
    amazon-cloudwatch-observability = {
      most_recent = true
    }
  }

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  depends_on = [aws_cloudwatch_log_group.eks]

  tags = {
    Environment = "production"
  }
}