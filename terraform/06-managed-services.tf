resource "aws_security_group" "managed_services" {
  name        = "${var.cluster_name}-managed-services"
  description = "Private data services accessible only from EKS nodes"
  vpc_id      = module.vpc.vpc_id

}

resource "aws_vpc_security_group_ingress_rule" "msk_from_eks" {
  security_group_id            = aws_security_group.managed_services.id
  description                  = "MSK TLS from EKS nodes"
  from_port                    = 9094
  to_port                      = 9094
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_eks" {
  security_group_id            = aws_security_group.managed_services.id
  description                  = "Redis TLS from EKS nodes"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_from_eks" {
  security_group_id            = aws_security_group.managed_services.id
  description                  = "OpenSearch HTTPS from EKS nodes"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "managed_services_egress" {
  security_group_id = aws_security_group.managed_services.id
  description       = "Managed services responses"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${var.cluster_name}/brokers"
  retention_in_days = 30
}

resource "aws_msk_cluster" "platform" {
  cluster_name           = "${var.cluster_name}-kafka"
  kafka_version          = "3.7.0"
  number_of_broker_nodes = 3
  enhanced_monitoring    = "PER_TOPIC_PER_BROKER"

  broker_node_group_info {
    instance_type   = "kafka.m7g.large"
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.managed_services.id]

    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    unauthenticated = true
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = {
    Environment = "production"
    Project     = "product-catalog"
  }
}

resource "aws_elasticache_subnet_group" "platform" {
  name       = "${var.cluster_name}-redis"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "platform" {
  replication_group_id       = "${var.cluster_name}-redis"
  description                = "Private Redis cache for product services"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.t4g.small"
  num_cache_clusters         = 2
  parameter_group_name       = "default.redis7"
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.platform.name
  security_group_ids         = [aws_security_group.managed_services.id]
  multi_az_enabled           = true
  automatic_failover_enabled = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  auth_token_update_strategy = "ROTATE"
  apply_immediately          = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_opensearch_domain" "platform" {
  domain_name    = "${var.cluster_name}-search"
  engine_version = "OpenSearch_2.13"
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "es:ESHttp*"
      Resource  = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/${var.cluster_name}-search/*"
    }]
  })

  cluster_config {
    instance_type          = "m7g.large.search"
    instance_count         = 3
    zone_awareness_enabled = true

    zone_awareness_config {
      availability_zone_count = 3
    }
  }

  vpc_options {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.managed_services.id]
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 100
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = false
    internal_user_database_enabled = false
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch.arn
    log_type                 = "ES_APPLICATION_LOGS"
    enabled                  = true
  }

  depends_on = [aws_cloudwatch_log_resource_policy.opensearch]

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Environment = "production"
    Project     = "product-catalog"
  }
}

resource "aws_cloudwatch_log_group" "opensearch" {
  name              = "/aws/opensearch/${var.cluster_name}"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_resource_policy" "opensearch" {
  policy_name = "${var.cluster_name}-opensearch-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "es.amazonaws.com"
      }
      Action = [
        "logs:PutLogEvents",
        "logs:PutLogEventsBatch",
        "logs:CreateLogStream",
      ]
      Resource = "${aws_cloudwatch_log_group.opensearch.arn}:*"
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.cluster_name}-rds-high-cpu"
  alarm_description   = "RDS CPU utilization exceeds 80 percent for 15 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    DBInstanceIdentifier = module.database.identifier
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "opensearch_red" {
  alarm_name          = "${var.cluster_name}-opensearch-red"
  alarm_description   = "OpenSearch cluster status is red"
  namespace           = "AWS/ES"
  metric_name         = "ClusterStatus.red"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    DomainName = aws_opensearch_domain.platform.domain_name
    ClientId   = data.aws_caller_identity.current.account_id
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "msk_offline_partitions" {
  alarm_name          = "${var.cluster_name}-kafka-offline-partitions"
  alarm_description   = "MSK reports one or more offline partitions"
  namespace           = "AWS/Kafka"
  metric_name         = "OfflinePartitionsCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    "Cluster Name" = aws_msk_cluster.platform.cluster_name
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${var.cluster_name}-rds-low-storage"
  alarm_description   = "RDS free storage is below 5 GiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 5368709120
  comparison_operator = "LessThanThreshold"
  dimensions = {
    DBInstanceIdentifier = module.database.identifier
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.cluster_name}-rds-high-connections"
  alarm_description   = "RDS has more than 80 concurrent client connections"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    DBInstanceIdentifier = module.database.identifier
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "${var.cluster_name}-redis-high-cpu"
  alarm_description   = "Redis CPU utilization exceeds 80 percent"
  namespace           = "AWS/ElastiCache"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.platform.id
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${var.cluster_name}-redis-high-memory"
  alarm_description   = "Redis memory usage exceeds 80 percent"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.platform.id
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "opensearch_jvm_memory" {
  alarm_name          = "${var.cluster_name}-opensearch-high-jvm-memory"
  alarm_description   = "OpenSearch JVM memory pressure exceeds 80 percent"
  namespace           = "AWS/ES"
  metric_name         = "JVMMemoryPressure"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    DomainName = aws_opensearch_domain.platform.domain_name
    ClientId   = data.aws_caller_identity.current.account_id
  }
  alarm_actions = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
  ok_actions    = var.alert_email == null || trimspace(var.alert_email) == "" ? [] : [aws_sns_topic.alerts[0].arn]
}

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${var.cluster_name}-platform"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "PostgreSQL"
          region = var.aws_region
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", module.database.identifier],
            [".", "FreeStorageSpace", ".", ".", { stat = "Minimum", yAxis = "right" }],
            [".", "DatabaseConnections", ".", ".", { yAxis = "right" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Managed data services"
          region = var.aws_region
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", aws_elasticache_replication_group.platform.id],
            [".", "DatabaseMemoryUsagePercentage", ".", "."],
            ["AWS/ES", "JVMMemoryPressure", "DomainName", aws_opensearch_domain.platform.domain_name, "ClientId", data.aws_caller_identity.current.account_id],
            ["AWS/Kafka", "OfflinePartitionsCount", "Cluster Name", aws_msk_cluster.platform.cluster_name, { stat = "Maximum", yAxis = "right" }],
          ]
        }
      },
    ]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "alerts" {
  count = var.alert_email == null || trimspace(var.alert_email) == "" ? 0 : 1
  name  = "${var.cluster_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email == null || trimspace(var.alert_email) == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "random_password" "redis_auth" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "runtime_config" {
  name                    = "${var.cluster_name}/platform/runtime-config"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "runtime_config" {
  secret_id = aws_secretsmanager_secret.runtime_config.id
  secret_string = jsonencode({
    DB_HOST                 = split(":", module.database.endpoint)[0]
    DB_PORT                 = "5432"
    DB_NAME                 = "product_catalog"
    REDIS_HOST              = aws_elasticache_replication_group.platform.primary_endpoint_address
    REDIS_PORT              = "6379"
    KAFKA_BOOTSTRAP_SERVERS = aws_msk_cluster.platform.bootstrap_brokers_tls
    OPENSEARCH_URIS         = "https://${aws_opensearch_domain.platform.endpoint}"
  })
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "${var.cluster_name}/redis/auth"
  recovery_window_in_days = 30
}

data "aws_iam_policy_document" "external_secrets_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume_role.json
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.runtime_config.arn,
      aws_secretsmanager_secret.redis_auth.arn,
      "${aws_secretsmanager_secret.app_db.arn}*",
      "${aws_secretsmanager_secret.search_db.arn}*",
      "${aws_secretsmanager_secret.cdc_db.arn}*",
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "${var.cluster_name}-external-secrets-read"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_secretsmanager_secret" "app_db" {
  name                    = "${var.cluster_name}/platform/app-db"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "cdc_db" {
  name                    = "${var.cluster_name}/platform/cdc-db"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "search_db" {
  name                    = "${var.cluster_name}/platform/search-db"
  recovery_window_in_days = 30
}

data "aws_iam_policy_document" "load_balancer_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "${var.cluster_name}-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_assume_role.json
}

resource "aws_iam_policy" "load_balancer_controller" {
  name = "${var.cluster_name}-load-balancer-controller"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteSecurityGroup",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:RevokeSecurityGroupIngress",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "iam:GetServerCertificate",
          "iam:ListServerCertificates",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:CreateProtection",
          "shield:DeleteProtection",
          "shield:DescribeProtection",
          "shield:GetSubscriptionState",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 90
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}
