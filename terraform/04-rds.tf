module "database" {
  source = "./modules/database"

  cluster_name            = var.cluster_name
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnets
  eks_node_security_group = module.eks.node_security_group_id
}

moved {
  from = aws_db_subnet_group.rds_subnet_group
  to   = module.database.aws_db_subnet_group.rds_subnet_group
}

moved {
  from = aws_security_group.rds_sg
  to   = module.database.aws_security_group.rds_sg
}

moved {
  from = aws_db_instance.postgres
  to   = module.database.aws_db_instance.postgres
}

moved {
  from = aws_db_parameter_group.postgres
  to   = module.database.aws_db_parameter_group.postgres
}
