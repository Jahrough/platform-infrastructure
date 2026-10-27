# Platform Infrastructure

Infrastructure-as-code, Kubernetes manifests, GitOps configuration, and
deployment automation for the Product Catalog platform. The repository
provisions private AWS infrastructure and deploys the catalog, search, and
change-data-capture (CDC) workloads.

> **Deployment status:** This repository describes infrastructure and
> deployment configuration; it does not mean the resources have been created.
> Terraform apply, Kubernetes deployment, and production service exposure are
> explicit operator actions. Review the [deployment runbook](DEPLOYMENT.md)
> before deploying.

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Local development](#local-development)
- [AWS infrastructure](#aws-infrastructure)
- [Production deployment](#production-deployment)
- [CI and validation](#ci-and-validation)
- [Security and operations](#security-and-operations)
- [Known prerequisites and limitations](#known-prerequisites-and-limitations)

## Architecture

```text
                         GitHub repository
                 Terraform / Kubernetes / Argo CD
                                  |
                                  v
                   Private Amazon EKS cluster
                    /            |           \
                   /             |            \
         product-catalog   product-search   Kafka Connect
                |                 |                |
                +--------+--------+----------------+
                         |
     +-------------------+------------------------------+
     |                   |              |               |
 Private PostgreSQL   Amazon MSK   ElastiCache Redis  OpenSearch
       (RDS)              TLS           TLS/encrypted   HTTPS
     |                   |              |               |
     +-------------------+--------------+---------------+
                         |
          AWS Secrets Manager + External Secrets
```

### AWS resources

Terraform defines:

- A three-Availability-Zone VPC with private subnets and one NAT gateway per
  zone.
- A private Amazon EKS cluster and managed node groups. The Kubernetes API
  endpoint is private-only.
- Private, encrypted, Multi-AZ PostgreSQL RDS with managed master credentials,
  backups, deletion protection, forced TLS, and logical replication settings.
- A three-broker Amazon MSK cluster using TLS client connections.
- Encrypted, TLS-enabled, Multi-AZ ElastiCache Redis with an AUTH token.
- A private, encrypted, three-node OpenSearch domain with HTTPS.
- AWS Secrets Manager secrets and narrowly scoped IRSA access for External
  Secrets Operator; an IRSA role for AWS Load Balancer Controller is also
  defined.
- CloudWatch logging/metrics configuration, log retention, and alarms for
  selected managed-service health conditions. Email alarm subscriptions are
  optional.

These are production-oriented managed services and can incur substantial
ongoing charges. Review instance sizes, storage, backup retention, NAT data
transfer, and regional service support before creating resources.

### Kubernetes and GitOps

- Argo CD's root application watches `argocd/apps/` (app-of-apps).
- External Secrets Operator synchronizes runtime and application credentials
  from AWS Secrets Manager into Kubernetes.
- The production Kustomize overlay deploys catalog and search workloads,
  Services, HPAs, and PodDisruptionBudgets.
- AWS Load Balancer Controller and Metrics Server are installed through Argo
  CD applications.
- Kafka Connect and the Debezium PostgreSQL connector are a separate,
  **manually synced** application. Deploy CDC only after the catalog has
  created its outbox table and its replication account has been bootstrapped.
- Application Services are internal `ClusterIP`s. An example HTTPS Ingress is
  provided but is not enabled by default.

## Repository layout

| Path | Purpose |
| --- | --- |
| `terraform/` | AWS providers, VPC, RDS, EKS, managed data services, IAM, alarms, and outputs |
| `kubernetes/base/` | Shared catalog and search Deployments, Services, and namespace |
| `kubernetes/overlays/dev/` | Development Kustomize overlay |
| `kubernetes/overlays/staging/` | Staging Kustomize overlay |
| `kubernetes/overlays/prod/` | Production ExternalSecrets, autoscaling, disruption budgets, and optional ingress template |
| `kubernetes/overlays/prod/cdc/` | Separate Kafka Connect deployment and CDC credential sync |
| `kubernetes/cluster-config/` | Cluster-scoped External Secrets configuration |
| `argocd/` | Root app-of-apps and Argo CD applications |
| `compose/` | Local PostgreSQL, Redis, Kafka, OpenSearch, Kafka Connect, and application Compose configuration |
| `connectors/` | Debezium outbox connector definition |
| `scripts/` | Database and CDC bootstrap, connector registration, and manifest validation scripts |
| `.github/workflows/` | CI validation, protected Terraform workflow, and Kafka Connect image publishing |
| `DEPLOYMENT.md` | Detailed production setup, bootstrap ordering, and operator commands |

## Prerequisites

### Local development and validation

- Docker Engine with Docker Compose v2.
- `kubectl` with Kustomize support.
- Terraform CLI version **1.10.5** for local Terraform operations.
- Python 3 and `yamllint` for the YAML lint workflow.
- Bash, AWS CLI, `jq`, `psql`, and Python 3 for the database bootstrap scripts.

The Compose application file builds from sibling repositories at
`../../product-catalog` and `../../product-search` relative to the Compose
configuration. Clone those application repositories beside this repository
when you want Compose to build the applications.

### Production

- An AWS account and region supporting the selected EKS version and all
  configured managed-service instance/engine versions.
- A VPC-connected operator or runner. The EKS API and RDS are not publicly
  reachable.
- An encrypted, versioned S3 bucket for Terraform state, with tightly scoped
  access. The Terraform state includes sensitive infrastructure values.
- A GitHub Actions OIDC role for Terraform, plus a protected GitHub
  `production` environment and required reviewers for applies.
- Argo CD installed in the cluster and repository access configured.
- Argo CD Image Updater installed and granted GHCR read access and narrowly
  scoped Git write access if automated image updates are desired.
- Real domain/DNS and ACM certificate values before enabling ingress.

## Local development

Set a local-only PostgreSQL password, then start the dependency stack and
applications from the repository root:

```sh
export POSTGRES_PASSWORD='use-a-local-development-password'
docker compose \
  -f compose/compose.yml \
  -f compose/compose.apps.yaml \
  up --build
```

The local endpoints are bound to loopback:

| Service | Local endpoint |
| --- | --- |
| Product Catalog | `http://localhost:8080` |
| Product Search | `http://localhost:8081` |
| PostgreSQL | `localhost:5432` |
| Redis | `localhost:6380` |
| OpenSearch | `http://localhost:9200` |
| Kafka | `localhost:9092` |
| Kafka Connect REST | `http://localhost:8083` |

Use `docker compose ... logs -f <service>` to inspect a service, and
`docker compose ... down` to stop the stack. Named volumes preserve local
PostgreSQL and OpenSearch data; remove volumes only when you intentionally
want to delete that development data.

The local OpenSearch service has its security plugin disabled. Do not expose it
outside a trusted development machine. Local Compose uses single-node,
development-oriented service configurations and is not a production
deployment.

## AWS infrastructure

The Terraform backend is intentionally configured externally. Create and
secure the state bucket before initializing Terraform. From the `terraform/`
directory:

```sh
terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="key=platform-infrastructure/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
```

Set a supported EKS version and review the plan:

```sh
export TF_VAR_cluster_version='SUPPORTED_EKS_VERSION'
terraform validate
terraform plan
```

Apply only after reviewing the complete plan and cost impact:

```sh
terraform apply
```

Terraform variables:

| Variable | Default | Description |
| --- | --- | --- |
| `aws_region` | `us-east-1` | AWS region for infrastructure |
| `cluster_name` | `product-catalog-cluster` | EKS cluster name and resource-name prefix |
| `cluster_version` | Required | EKS Kubernetes version supported in the chosen region |
| `alert_email` | `null` | Optional email endpoint for SNS alarm notifications |

See `terraform/outputs.tf` for cluster, service endpoint, secret-name, and IRSA
role outputs. Do not publish output values containing secrets. Use
`terraform output -raw <output_name>` only where a command specifically needs
an output.

The EKS endpoint is private-only. Run Terraform, `kubectl`, database bootstrap,
and other private endpoint operations from an appropriately connected network.
PostgreSQL logical replication and forced TLS use pending-reboot parameter
settings; complete the required RDS reboot before CDC setup. RDS, Redis, and
OpenSearch have deletion safeguards; review intentional destruction and
recovery requirements before changing those settings.

## Production deployment

Production setup is deliberately staged. At a high level:

1. Configure and initialize encrypted remote Terraform state; provision
   infrastructure from a VPC-connected operator.
2. Create the catalog and search application DB accounts and put their
   credentials in Secrets Manager with
   `scripts/bootstrap-app-databases.sh`.
3. Configure the Terraform-derived IRSA role, VPC, cluster, and region values
   in the Argo CD application manifests.
4. Install Argo CD and apply `argocd/root-app.yaml`. Confirm External Secrets
   has synchronized required secrets before application workloads start.
5. Configure Argo CD Image Updater and GHCR access if image automation is
   required.
6. After catalog migrations create `public.outbox`, reboot RDS if required,
   create the CDC user with `scripts/bootstrap-cdc-user.sh`, manually sync
   `product-cdc`, then register the connector with
   `scripts/register-outbox-connector.sh`.
7. For public access, configure the example Ingress with a real DNS hostname
   and ACM certificate, add it to the production Kustomization, and create
   the corresponding DNS aliases.

**Configuration alignment:** The current External Secrets manifests use
`us-east-1` and secret names prefixed with the default
`product-catalog-cluster`. If you change `aws_region` or `cluster_name`, update
`kubernetes/cluster-config/cluster-secret-store.yaml` and the
`remoteRef.key` values in production ExternalSecrets (including the CDC
overlay) before syncing Argo CD.

The complete, ordered commands and detailed prerequisites are in
[DEPLOYMENT.md](DEPLOYMENT.md). Do not skip the bootstrap steps: Terraform
creates several Secrets Manager secrets before their application credential
values exist.

## CI and validation

### Validate infrastructure

`.github/workflows/validate.yml` runs for relevant pull requests and pushes to
`main`. It checks:

- YAML formatting with `yamllint`.
- Kustomize rendering for dev, staging, production, CDC, and cluster config.
- Compose configuration using a validation-only PostgreSQL password.
- Connector JSON and shell script syntax.
- Terraform formatting, initialization, and validation.

Run equivalent checks locally from the repository root:

```sh
set -e
yamllint argocd kubernetes compose .github/workflows
kubectl kustomize kubernetes/overlays/dev >/dev/null
kubectl kustomize kubernetes/overlays/staging >/dev/null
kubectl kustomize kubernetes/overlays/prod >/dev/null
kubectl kustomize kubernetes/overlays/prod/cdc >/dev/null
kubectl kustomize kubernetes/cluster-config >/dev/null
POSTGRES_PASSWORD=validation-only-password \
  docker compose -f compose/compose.yml -f compose/compose.apps.yaml config --quiet
python3 -m json.tool connectors/postgres-outbox-connector.json >/dev/null
for file in scripts/*.sh; do bash -n "$file"; done
git diff --check
```

From `terraform/`, run:

```sh
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

### Terraform deployment workflow

`.github/workflows/terraform.yml` is manual-dispatch only. It always creates a
plan; the `apply` selection applies the saved plan after any required approval
for the protected `production` environment.

Configure these GitHub Actions environment variables:

| Variable | Purpose |
| --- | --- |
| `TERRAFORM_AWS_ROLE_ARN` | Least-privilege AWS role assumed through GitHub OIDC |
| `AWS_REGION` | Deployment region |
| `TF_STATE_BUCKET` | Encrypted, versioned Terraform state bucket |
| `TF_STATE_KEY` | Unique Terraform state object key |
| `CLUSTER_VERSION` | Supported EKS version |
| `ALERT_EMAIL` | Optional SNS email subscription |

Protect the `production` environment with reviewers and ensure the OIDC role
has only the permissions required to manage this stack.

### Kafka Connect image

`.github/workflows/publish-kafka-connect.yml` builds the custom Kafka Connect
image, scans it for fixable high/critical vulnerabilities, and publishes it
to GHCR with SBOM and provenance attestations. Review image tags, scanner
results, and upstream base-image/connector releases as part of routine
maintenance.

## Security and operations

- Keep Terraform state in a private, encrypted, versioned bucket with
  restricted read/write access. State can contain sensitive values.
- Do not commit credentials, runtime secret values, kubeconfigs, Terraform
  state, or local development passwords.
- Application credentials are created interactively by bootstrap scripts and
  stored in Secrets Manager; the scripts avoid printing generated passwords.
- EKS workloads use non-root identities, restricted container security
  contexts, resource requests/limits, and health probes where configured.
- Managed data services use private networking and encryption/TLS as
  configured. OpenSearch access is additionally limited at the VPC security
  group boundary; keep that boundary private and controlled.
- Configure and confirm the optional SNS email subscription if alarms should
  page an operator. Establish ownership for CloudWatch logs, alarms, backups,
  and restore testing.
- The HPA requires Metrics Server. Recovery objectives and a tested RDS and
  application restore procedure should be established before production use.
- Application and Kafka Connect REST Services are internal. Restrict access to
  the connector registration endpoint to trusted operators and workloads.

## Known prerequisites and limitations

- Terraform does **not** create a DNS name, ACM certificate, Route 53 records,
  or public ingress. The Ingress file is an example template and is excluded
  from the active production overlay until configured.
- Argo CD, Argo CD Image Updater, and the GHCR access policy must be installed
  or configured by the operator. Terraform does not install Argo CD itself.
- External Secrets' region and remote secret names currently assume the
  Terraform defaults; keep them aligned if changing the region or cluster
  name.
- Kafka Connect CDC is intentionally not automatically deployed. It depends
  on application migrations and a PostgreSQL replication user/publication.
- Dev and staging overlays provide Kubernetes configuration, not separate
  Terraform-managed AWS environments.
- The managed-service architecture has significant costs; run a reviewed
  Terraform plan and estimate expected monthly spend before applying.
- Dashboards, distributed tracing, centralized application-log configuration,
  and a complete on-call/runbook program are not fully supplied here.
- AWS service versions, chart versions, GitHub Actions, and application image
  tags should be reviewed and updated through normal dependency and security
  maintenance.

## Contributing

Keep infrastructure and manifests validated, avoid embedding environment
secrets, and update [DEPLOYMENT.md](DEPLOYMENT.md) when bootstrap behavior or
operator steps change. Changes that alter AWS resources should include a
review of Terraform plan impact, security boundaries, availability, and cost.
