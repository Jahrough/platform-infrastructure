# Deployment

This runbook provisions private AWS infrastructure and deploys its workloads
in stages. It does not imply that any AWS resource or Kubernetes workload
already exists.

## Ownership and source selection

Terraform in this repository owns AWS infrastructure and its lifecycle.
`platform-gitops` is intended to own Argo CD configuration and Kubernetes
desired state, while individual service repositories own application
behavior, migrations, and event contracts. This repository currently also
contains Argo CD and Kubernetes declarations, so that intended separation is
not yet reflected in all repository contents.

Before bootstrapping or syncing Argo CD, inventory existing Applications and
their managed resources, choose one authoritative source for each resource,
and agree on a migration. Do not run both repositories' roots against the
same cluster resources. The Argo CD and manifest commands later in this
runbook refer to the current in-repository configuration; use them only after
the ownership check and review.

## Platform components and cost

Terraform provisions a three-AZ VPC with one NAT gateway per AZ, private EKS,
Multi-AZ PostgreSQL RDS, three-broker MSK, encrypted Multi-AZ Redis, and a
three-node VPC OpenSearch domain. It also configures External Secrets access,
CloudWatch logs/metrics, a platform dashboard, selected resource alarms, and
IAM roles for External Secrets and AWS Load Balancer Controller. Production
alerts require an SNS email owner.

The managed services have significant ongoing costs. Before applying, review
the instance/storage choices, EKS node sizing, backup retention, NAT data
transfer, AWS regional support, availability requirements, and recovery
objectives. Use the AWS Pricing Calculator for an account- and region-specific
estimate; Terraform plan is not a cost estimate.

## 1. Terraform state and AWS identity

Use an AWS administrative bootstrap identity to create a unique state bucket:

```sh
bash scripts/bootstrap-terraform-state.sh YOUR_UNIQUE_STATE_BUCKET us-east-1
```

The script enables server-side encryption, versioning, public-access blocking,
owner-enforced object ownership, and a policy denying non-TLS requests. Grant
only the Terraform deployment role access to this bucket and its lock file.

For GitHub Actions, create the AWS IAM OIDC provider for
`token.actions.githubusercontent.com` if the account does not already have
one. Use [.github/aws/terraform-oidc-trust-policy.example.json](.github/aws/terraform-oidc-trust-policy.example.json)
as a trust-policy starting point: replace the AWS account ID and preserve the
repository and `production` environment subject restriction. Attach a
reviewed, least-privilege permissions policy for this Terraform stack and the
state bucket. The example is a trust policy, not a complete permissions
policy.

From `terraform/`, initialize the remote backend:

```sh
terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="key=platform-infrastructure/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
```

## 2. Choose deployment settings and apply Terraform

Discover an EKS Kubernetes version with standard support in the deployment
region:

```sh
aws eks describe-cluster-versions \
  --region us-east-1 \
  --query 'clusterVersions[?status==`STANDARD_SUPPORT`].clusterVersion' \
  --output table
```

Set the version and a real alert-owner email, then review and apply:

```sh
export TF_VAR_cluster_version='SUPPORTED_EKS_VERSION'
export TF_VAR_alert_email='oncall@example.com'
terraform validate
terraform plan
terraform apply
```

The private EKS API endpoint and RDS endpoint require a VPC-connected
operator/runner. Terraform state can contain sensitive infrastructure values;
keep it encrypted and tightly access-controlled. RDS logical replication and
forced TLS use pending-reboot parameter settings. Complete the required RDS
reboot before CDC bootstrap. RDS, Redis, and OpenSearch have deletion
safeguards; plan intentional teardown separately.

### GitHub Actions configuration

Create a protected GitHub environment named `production`; require reviewers
for applies and limit allowed deployment branches. Configure these
environment variables:

| Variable | Purpose |
| --- | --- |
| `TERRAFORM_AWS_ROLE_ARN` | Least-privilege AWS OIDC deployment role |
| `AWS_REGION` | AWS region for this environment |
| `TF_STATE_BUCKET` | Encrypted, versioned state bucket |
| `TF_STATE_KEY` | Unique Terraform state key |
| `CLUSTER_VERSION` | EKS version discovered as supported in the region |
| `ALERT_EMAIL` | Required email address for alarm notifications |

The workflow checks required settings, reports the assumed AWS identity, and
checks the selected EKS version against the region's support status. A
successful plan exercises read/plan permissions; apply permissions are
exercised when changed resources are applied. Review the IAM role's effective
permissions and CloudTrail activity; the workflow cannot certify permission
for every future Terraform change.

The Terraform workflow is manual-dispatch only. It always plans; choosing
`apply` applies that workflow run's saved plan after protected-environment
approval. Confirm the SNS email subscription after the first apply.

## 3. Bootstrap application database credentials

Run this from a protected machine that can reach the private RDS endpoint.
The script securely prompts for catalog and search passwords, creates the
database roles/database, and stores credentials in Secrets Manager:

```sh
bash scripts/bootstrap-app-databases.sh \
  "$(terraform -chdir=terraform output -raw rds_endpoint)" \
  "$(terraform -chdir=terraform output -raw rds_master_secret_arn)" \
  "$(terraform -chdir=terraform output -raw app_database_secret_name)" \
  "$(terraform -chdir=terraform output -raw search_database_secret_name)" \
  "$(terraform -chdir=terraform output -raw aws_region)"
```

Do not print, commit, or pass generated passwords on command lines.

## 4. Configure Argo CD from Terraform outputs

Install Argo CD in EKS and grant it read access to this repository. Generate
the IAM role ARNs, cluster/VPC names, AWS region, and Secrets Manager name
prefix from applied Terraform outputs:

```sh
python3 scripts/configure-argocd-from-terraform.py
git diff -- argocd/apps kubernetes/cluster-config kubernetes/overlays/prod
```

The script requires an initialized Terraform directory with applied outputs.
It writes only non-secret infrastructure identifiers into the Argo CD and
External Secrets manifests. Review and commit these changes so the GitOps
source contains the configured values. Re-run after changing the cluster name
or region.

## 5. Pin images and deploy the applications

Before syncing production, obtain reviewed image digests from the published
GHCR images and replace all fail-closed zero digest pins:

```sh
python3 scripts/set-image-digests.py \
  --catalog-digest sha256:CATALOG_IMAGE_DIGEST \
  --search-digest sha256:SEARCH_IMAGE_DIGEST \
  --connect-digest sha256:KAFKA_CONNECT_IMAGE_DIGEST
```

Commit the resulting Kustomize changes. The example all-zero digests
intentionally cannot be pulled. Argo CD Image Updater is configured to write
future digest updates to Kustomize; install/configure it with GHCR read access
and narrowly scoped Git write access.

Apply the app-of-apps root:

```sh
kubectl apply -f argocd/root-app.yaml
```

Verify External Secrets Operator and the ClusterSecretStore are healthy,
then verify the catalog/search ExternalSecrets report `Ready` and the required
Kubernetes Secrets exist **without displaying their values**. Confirm the EKS
nodes can pull the GHCR images. Check pod events/logs and application
readiness before considering deployment complete.

The production CNI network-policy controller is enabled through the EKS
VPC CNI add-on. Production egress NetworkPolicies allow CoreDNS and the
required data-service ports within the VPC CIDR. Validate DNS and each
application dependency after sync. If the VPC CIDR changes, update and review
these policies.

## 6. Optional ingress and DNS

Applications remain internal `ClusterIP`s unless you explicitly enable
ingress. Obtain an ACM certificate in the deployment region for a domain you
control, then generate the ingress:

```sh
python3 scripts/enable-ingress.py \
  --domain example.com \
  --certificate-arn arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000 \
  --region us-east-1 \
  --scheme internet-facing
```

The command writes `kubernetes/overlays/prod/ingress.yaml` and adds it to the
production Kustomization. Review and commit those changes. The default
`internet-facing` scheme exposes the apps publicly; use `--scheme internal`
for a private ALB. After the controller provisions the ALB, create DNS aliases
for the catalog/search hostnames and verify HTTPS and health checks.

## 7. Set up CDC after catalog migrations

Wait until catalog migrations have created `public.outbox`. Ensure the RDS
logical-replication parameter is active (reboot if required), then create the
replication role and Secrets Manager value:

```sh
bash scripts/bootstrap-cdc-user.sh \
  "$(terraform -chdir=terraform output -raw rds_endpoint)" \
  "$(terraform -chdir=terraform output -raw rds_master_secret_arn)" \
  "$(terraform -chdir=terraform output -raw cdc_database_secret_name)" \
  "$(terraform -chdir=terraform output -raw aws_region)"
```

Manually sync the `product-cdc` Argo CD Application after the CDC External
Secret has synchronized. Register the connector from a trusted host that can
reach its internal REST service:

```sh
bash scripts/register-outbox-connector.sh
```

Check connector status, MSK partition alarms, replication slots/publications,
and downstream indexing. Avoid deleting a slot or resetting offsets without
understanding the replay/data-loss consequences.

## Security boundaries and operational gaps

MSK TLS connections are currently unauthenticated within the EKS node
security-group boundary; OpenSearch fine-grained authentication is disabled.
The application clients in the separate product repositories do not yet
configure the authenticated MSK/OpenSearch protocols. Production egress
NetworkPolicies and private service security groups restrict reachability,
but do **not** create per-client protocol identities. Do not treat those
network controls as equivalent to SASL/IAM or OpenSearch user authentication.

Terraform creates a CloudWatch platform dashboard, selected service alarms,
and CloudWatch collection for cluster/container logs and metrics. It does not
provide an application metrics scraper, trace collector/backend, or complete
on-call program. Review
[OPERATIONS.md](OPERATIONS.md) for alarm triage, network policy checks, and
the RDS point-in-time restore exercise.

RDS has seven days of automated backup retention. Cross-region backup
replication and automated regional failover are not configured. Define RPO/RTO
with the service owner, implement a destination-region recovery design, and
perform an isolated restore exercise before claiming disaster recovery.

## Local Compose

Set `POSTGRES_PASSWORD`, then start the dependency and application services
from the repository root:

```sh
export POSTGRES_PASSWORD='use-a-local-development-password'
docker compose -f compose/compose.yml -f compose/compose.apps.yaml up --build
```

The Compose stack is single-node and development-only. OpenSearch has its
security plugin disabled and all published ports are bound to loopback; do
not expose it outside a trusted development machine.
