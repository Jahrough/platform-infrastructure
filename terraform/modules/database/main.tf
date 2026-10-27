resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "product-catalog-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "product-db-subnet-group"
  }
}

resource "aws_security_group" "rds_sg" {
  name   = "product-rds-security-group"
  vpc_id = var.vpc_id

  ingress {
    description     = "PostgreSQL access from EKS worker nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_parameter_group" "postgres" {
  name   = "${var.cluster_name}-postgres15"
  family = "postgres15"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "postgres" {
  identifier                  = "product-db"
  engine                      = "postgres"
  engine_version              = "15.4"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  max_allocated_storage       = 100
  db_name                     = "product_catalog"
  username                    = "postgres"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.rds_subnet_group.name
  parameter_group_name        = aws_db_parameter_group.postgres.name
  vpc_security_group_ids      = [aws_security_group.rds_sg.id]
  storage_encrypted           = true
  backup_retention_period     = 7
  multi_az                    = true
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "product-db-final-snapshot"
  publicly_accessible         = false
  auto_minor_version_upgrade  = true

  tags = {
    Environment = "production"
  }

  lifecycle {
    prevent_destroy = true
  }
}
