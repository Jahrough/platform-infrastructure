# Operations and recovery

This runbook describes checks and recovery actions for the infrastructure in
this repository. Execute restore procedures in an isolated recovery
environment first. A successful command is not proof of application
consistency; validate the recovered data and workload before routing traffic.

Terraform owns the AWS infrastructure and cloud-side permissions;
`platform-gitops` owns Kubernetes desired state, and service repositories own
application behavior and data migrations. Before changing or recovering
workloads, confirm which source currently reconciles each resource; do not
enable overlapping Argo CD roots.

## Signals and ownership

- The Terraform-managed CloudWatch dashboard is named
  `<cluster-name>-platform`. It summarizes PostgreSQL, Redis, OpenSearch, and
  MSK metrics.
- CloudWatch alarms cover RDS CPU, low free storage and connection count,
  OpenSearch red health and JVM memory pressure, Redis CPU and memory use, and
  MSK offline partitions.
- `alert_email` is required for Terraform deployment. Confirm the SNS
  subscription email after the first apply and record a primary and backup
  human owner for the inbox and alarm response.
- The EKS CloudWatch Observability add-on collects cluster/container logs and
  metrics. Inspect the `/aws/containerinsights/<cluster-name>/application`
  and related Container Insights log groups in the AWS console.
- Applications expose Actuator health and Prometheus metrics. No Prometheus
  scraper, long-term metrics store, dashboard for application metrics, or
  OpenTelemetry trace collector/backend is provisioned here. Do not treat
  application traces as retained or monitored until an exporter and backend
  are deployed and tested.

## Incident triage

1. Check the CloudWatch dashboard and alarm history; note the first failing
   signal and timestamp.
2. Check EKS nodes and workloads from a VPC-connected operator:

   ```sh
   kubectl get nodes
   kubectl -n platform-production get pods,services,hpa,pdb
   kubectl -n platform-production get events --sort-by=.lastTimestamp
   ```

3. Inspect the affected pod's logs and probes:

   ```sh
   kubectl -n platform-production logs deploy/product-catalog --since=30m
   kubectl -n platform-production logs deploy/product-search --since=30m
   ```

4. For missing External Secrets, inspect the ExternalSecret and ClusterSecretStore
   status, External Secrets Operator logs, and IAM/Secrets Manager access. Do
   not print secret values while troubleshooting.
5. For a database or managed-service incident, preserve the current state,
   consult the relevant AWS service events, and follow the recovery procedure
   below before changing endpoints or credentials.

## PostgreSQL point-in-time recovery exercise

RDS automated backups are configured with a seven-day retention period.
Perform a restore exercise before production, then repeat on a documented
schedule. The following example restores the latest restorable point as a new
instance; substitute a unique identifier and confirm the subnet group,
security group, KMS key, and target region match the recovery environment:

```sh
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier product-db \
  --target-db-instance-identifier product-db-restore-YYYYMMDD \
  --use-latest-restorable-time \
  --db-subnet-group-name product-catalog-db-subnet-group \
  --vpc-security-group-ids REPLACE_WITH_RECOVERY_RDS_SECURITY_GROUP \
  --multi-az \
  --no-publicly-accessible \
  --region "$AWS_REGION"

aws rds wait db-instance-available \
  --db-instance-identifier product-db-restore-YYYYMMDD \
  --region "$AWS_REGION"

aws rds describe-db-instances \
  --db-instance-identifier product-db-restore-YYYYMMDD \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region "$AWS_REGION"
```

Validate database connectivity from a protected VPC-connected host, expected
databases and roles, application schema/migrations, row counts or business
invariants, and an application smoke test. Keep restored systems isolated
until an authorized operator approves recovery. Record the observed recovery
point, restore duration, validation results, and follow-up actions. Remove
test instances and snapshots only after retaining the exercise evidence and
confirming they are not needed.

The configured backup retention is **not** cross-region disaster recovery.
Cross-region backup replication, failover networking, DNS cutover, and
application recovery automation are not provisioned. Define RPO/RTO with the
service owner and implement/test a destination-region backup and failover
design before claiming regional disaster recovery.

## CDC recovery

Kafka Connect is manually synced and uses Kafka's internal topics for
connector configuration, offsets, and status. Before restarting or
re-registering Debezium, check Connect's `/connectors` and connector status,
MSK broker/partition alarms, RDS replication settings, and the publication
and replication slot. Avoid deleting a slot or resetting connector offsets
without understanding the resulting replay or data-loss behavior.

The connector endpoint is internal. Run
`scripts/register-outbox-connector.sh` only from a trusted host with network
access to the service. Validate consumer lag and downstream indexing after
connector recovery.

## Network policy validation

Production egress policies permit app-specific database, cache, Kafka, and
OpenSearch ports to the VPC CIDR and DNS to CoreDNS. They rely on the EKS VPC
CNI network-policy controller and the managed-service security groups. After
first sync, verify DNS resolution and health/readiness for each application
and CDC workload. If the VPC or subnet CIDRs change, update policy CIDRs and
review the rendered policies before deployment.

These are network-level controls, not protocol-level client identities.
MSK currently permits TLS clients from the EKS node security group without
SASL/IAM authentication, and OpenSearch fine-grained authentication is not
enabled. The application clients in the adjacent service repositories must
support authenticated protocols before enabling them here. Treat node access
and the private VPC as trusted security boundaries until that integration is
completed.
