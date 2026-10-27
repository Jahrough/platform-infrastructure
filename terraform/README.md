# Terraform layout

This directory is the existing single Terraform root for the platform. It
retains the current S3 backend declaration and resource naming. No separate
dev, staging, or production state roots are configured here.

## Composition

- `01-providers.tf` declares Terraform/provider constraints and the S3 backend.
- `02-variables.tf` contains root inputs.
- `03-vpc.tf` composes the pinned upstream VPC module.
- `04-rds.tf` composes the local PostgreSQL module.
- `05-eks.tf` composes the pinned upstream EKS module.
- `06-managed-services.tf` currently contains managed messaging, cache,
  search, IAM integration, secrets, and observability resources.
- `outputs.tf` exposes the non-password connection identifiers consumed by
  operator workflows and downstream configuration.
- `modules/database/` owns the PostgreSQL instance, subnet group, security
  group, and parameter group.

The database module takes the VPC ID, private subnet IDs, cluster-name prefix,
and EKS node security group as inputs. It exposes the private RDS endpoint,
instance identifier, and AWS-managed master-secret ARN. It does not expose
database password values.

## Ownership and downstream contract

Terraform owns the AWS resources composed by this root, including the EKS
cluster foundations, AWS add-ons configured through the EKS module, managed
data services, IAM roles/policies, Secrets Manager resources, and
infrastructure outputs. It does not define application Deployments, Services,
Argo CD Applications, application schemas, or business behavior.

Argo CD Applications and Kubernetes manifests are maintained in the separate
`platform-gitops` repository. A source-code move does not establish whether an
older Argo CD root is active in a cluster; inventory live ownership and
complete a deliberate handoff before syncing the GitOps repository.

Outputs are handoff metadata for authorized operators and GitOps
configuration: cluster and VPC identifiers, private service endpoints, secret
names/ARNs, and controller role ARNs. They are not a substitute for
credentials. Keep secret values out of outputs, Git, and logs; Terraform state
remains sensitive even when outputs omit those values.

## State and migration safety

The root's `04-rds.tf` includes moved blocks mapping the former root-level
database resource addresses into `module.database`. These declarations
describe address transitions; they do not inspect or modify remote state by
themselves. Before using this refactor against a real backend, an authorized
operator must verify the configured backend and actual resource addresses,
review a plan for unexpected create/replace/destroy actions, and retain a
recoverable state version. Do not remove the moved blocks or change the
backend/state key without a separately approved migration.

Terraform state and saved plans are sensitive. The state bucket and access
policy are bootstrapped separately; use encryption, versioning, the S3 lock
file, restricted access, and the recovery procedure established by the
account owner. No state retrieval, migration, plan, or apply is performed by
this repository documentation.

## Environment strategy

There are no implemented environment-specific roots. Do not create isolated
environment roots until account/region boundaries, budgets, deployment
roles, private operator access, and existing production state ownership are
confirmed. Keep the current root as the production composition in the interim.

New environments should use distinct state keys and narrowly scoped AWS
roles. They should compose the shared modules with explicit, validated
environment inputs; avoid copying production sizing or enabling every managed
data service by default. Local development continues to use the repository's
Compose stack without AWS.
