# Platform Infrastructure

Terraform infrastructure-as-code and local development configuration for the
Product Catalog platform. This repository provisions AWS foundations and
managed services. It currently also contains Kubernetes manifests and Argo CD
configuration; their intended long-term owner is the separate
`platform-gitops` repository.

> **Deployment status:** This repository describes infrastructure and
> deployment configuration; it does not mean the resources have been created.
> Terraform apply, Kubernetes deployment, and production service exposure are
> explicit operator actions. Review the [deployment runbook](DEPLOYMENT.md)
> before deploying.

> **Ownership transition:** Do not configure both repositories' Argo CD roots
> to reconcile the same cluster resources. The Kubernetes and Argo CD files
> currently present here must be inventoried and deliberately transitioned
> before `platform-gitops` becomes the active source for those resources.

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
               Terraform foundations / GitOps desired state
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
- Production egress NetworkPolicies for catalog, search, and Kafka Connect,
  enforced by the EKS VPC CNI network-policy controller.
- AWS Secrets Manager secrets and narrowly scoped IRSA access for External
  Secrets Operator; an IRSA role for AWS Load Balancer Controller is also
  defined.
- A CloudWatch platform dashboard and alarms for selected RDS, Redis,
  OpenSearch, and MSK health/capacity signals. A required SNS email
  subscription provides an explicit notification owner.

These are production-oriented managed services and can incur substantial
ongoing charges. Review instance sizes, storage, backup retention, NAT data
transfer, and regional service support before creating resources.

### Ownership boundaries

| Owner | Responsibility |
| --- | --- |
| This repository (`platform-infrastructure`) | Terraform-managed AWS foundations, networking, EKS infrastructure and AWS add-ons, managed data services, IAM, secrets storage, and infrastructure outputs. Compose supports AWS-independent local development. |
| `platform-gitops` | Argo CD projects/applications and Kubernetes desired state: controllers, application Deployments and Services, External Secrets resources, policies, ingress, and rollout configuration. |
| Individual service repositories | Application behavior, APIs, tests, database migrations and schemas, event contracts, and service-specific instrumentation. |

This repository still contains Kubernetes manifests and Argo CD definitions,
so the ownership boundary has not yet been completed in the repository
contents. Treat those declarations as a transition requiring an explicit
resource inventory and migration; do not have two Argo CD sources manage the
same resource. Terraform may provision cloud identities and permissions used
by GitOps-installed controllers, but it should not manage the same Kubernetes
resources that Argo CD reconciles. The deployment runbook documents the
current in-repository procedures and their prerequisites.

## Repository layout

| Path | Purpose |
| --- | --- |
| `terraform/` | Single production-root composition, VPC/EKS modules, database module, managed data services, IAM, alarms, and outputs |
| `terraform/modules/database/` | Reusable PostgreSQL instance, subnet group, security group, and parameter group |
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
| `.github/aws/` | GitHub Actions OIDC trust-policy example |
| `OPERATIONS.md` | Monitoring, incident triage, network policy validation, and recovery exercises |
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
- AWS permissions to bootstrap the Terraform state bucket and create the OIDC
  deployment role.
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

The Terraform backend is intentionally configured externally. Create and secure the state bucket before initializing Terraform. The helper
uses the caller's AWS CLI identity and enables versioning, server-side
encryption, public-access blocking, owner-enforced object ownership, and a
TLS-only bucket policy:

```sh
bash scripts/bootstrap-terraform-state.sh \
  YOUR_GLOBALLY_UNIQUE_STATE_BUCKET \
  us-east-1
```

Run it using an administrative bootstrap identity, then restrict bucket and
lock-file access to the Terraform deployment role. Create a GitHub OIDC
provider in IAM if the AWS account does not already have one. Use
`.github/aws/terraform-oidc-trust-policy.example.json` as the trust-policy
starting point; replace the AWS account ID and scope the subject to the
`production` GitHub environment. Attach a reviewed, least-privilege
permissions policy for this Terraform stack and the specific state bucket.
The workflow verifies its configured identity and version but cannot prove
that every future apply action is authorized until Terraform plans/applies
the relevant resources.

Discover an EKS version currently supported in the chosen region, then set it
as `TF_VAR_cluster_version`:

```sh
aws eks describe-cluster-versions \
  --region us-east-1 \
  --query 'clusterVersions[?status==`STANDARD_SUPPORT`].clusterVersion' \
  --output table
```

From the `terraform/` directory, initialize the S3 backend:

```sh
terraform init \
  -backend-config="bucket=YOUR_STATE_BUCKET" \
  -backend-config="key=platform-infrastructure/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
```

The state bucket can be bootstrapped with `scripts/bootstrap-terraform-state.sh`.
An AWS OIDC trust-policy example is in `.github/aws/`; the stack permissions
policy still must be reviewed and attached by an AWS administrator.

Set a supported EKS version and review the plan:

```sh
export TF_VAR_cluster_version='SUPPORTED_EKS_VERSION'
export TF_VAR_alert_email='oncall@example.com'
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
| `alert_email` | Required | SNS alarm notification owner email |

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
2. Bootstrap the app database accounts and store their credentials in
   Secrets Manager with `scripts/bootstrap-app-databases.sh`.
3. Generate Argo CD and External Secrets settings from Terraform outputs:

   ```sh
   python3 scripts/configure-argocd-from-terraform.py
   git diff -- argocd/apps kubernetes/cluster-config kubernetes/overlays/prod
   ```

   Review and commit the generated non-secret values before Argo CD reads the
   repository. Re-run the generator after changing Terraform's cluster or
   region configuration.
4. Pin production images by digest before syncing:

   ```sh
   python3 scripts/set-image-digests.py \
     --catalog-digest sha256:CATALOG_IMAGE_DIGEST \
     --search-digest sha256:SEARCH_IMAGE_DIGEST \
     --connect-digest sha256:KAFKA_CONNECT_IMAGE_DIGEST
   ```

   Obtain the digests from reviewed GHCR release images and commit the
   resulting Kustomize changes. The example zero digests intentionally cannot
   be pulled. Argo CD Image Updater is configured to write later digest
   updates to Kustomize.
5. Install Argo CD and apply `argocd/root-app.yaml`. Confirm External Secrets
   has synchronized required secrets before application workloads start.
6. Configure Argo CD Image Updater and GHCR access if image automation is
   required.
7. After catalog migrations create `public.outbox`, reboot RDS if required,
   create the CDC user with `scripts/bootstrap-cdc-user.sh`, manually sync
   `product-cdc`, then register the connector with
   `scripts/register-outbox-connector.sh`.
8. For public access, use a real DNS zone and ACM certificate to render and
   enable the example Ingress:

   ```sh
   python3 scripts/enable-ingress.py \
     --domain example.com \
     --certificate-arn arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000 \
     --region us-east-1 \
     --scheme internet-facing
   ```

   Review and commit the generated Ingress and Kustomize changes, then create
   Route 53 aliases for the provisioned ALB. Choose `--scheme internal` for
   private-only access.

The generator keeps External Secrets region and secret prefixes aligned with
Terraform outputs. Do not sync the production applications until it has run
and every required image digest has been replaced.

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

The Terraform configuration remains a single root using the existing S3
backend. The PostgreSQL resources are grouped in a local module with explicit
VPC, subnet, and EKS-node-security-group inputs. The VPC and EKS registry
modules remain directly composed at the root to preserve their existing
addresses. The other managed-service, IAM, and observability resources remain
in the root until their state mappings and environment requirements are
reviewed. Empty environment directories are not deployment configurations;
do not infer that dev/staging stacks exist or initialize separate state for
them.

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
python3 -m py_compile scripts/*.py
git diff --check
```

Before deploying production manifests, run
`python3 scripts/validate-production-config.py`. It fails while Terraform
tokens, ingress placeholders in active configuration, or zero image digests
remain.

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
| `ALERT_EMAIL` | Required SNS alarm notification owner email |

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
  configured. Production NetworkPolicies restrict workload egress to DNS and
  the required managed-service ports; security groups remain an additional
  boundary.
- **Protocol authentication is not yet enabled for MSK or OpenSearch.** MSK
  accepts TLS connections from the EKS node security group without SASL/IAM
  client authentication, and OpenSearch fine-grained authentication is
  disabled. Network policies reduce reachability but do not provide
  per-client identity. Enable authenticated protocols only after the
  application clients support and test them.
- Confirm the required SNS email subscription and assign a primary and backup
  owner. Terraform creates a CloudWatch dashboard and selected resource
  alarms; application dashboards and full on-call coverage still need setup.
- EKS CloudWatch Observability collects container logs/metrics, but no
  OpenTelemetry trace collector/backend or application metrics scraper is
  installed.
- RDS has seven days of automated backup retention. Run the isolated restore
  exercise in [OPERATIONS.md](OPERATIONS.md) before production and on a
  schedule. Cross-region backup replication and automatic regional failover
  are not provisioned; set RPO/RTO with the service owner before claiming
  disaster recovery.
- Application and Kafka Connect REST Services are internal. Restrict access to
  the connector registration endpoint to trusted operators and workloads.

## Known prerequisites and limitations

- Terraform does **not** create a DNS name, ACM certificate, Route 53 records,
  or public ingress. The Ingress file is an example template and is excluded
  from the active production overlay until configured.
- Argo CD, Argo CD Image Updater, and the GHCR access policy must be installed
  or configured by the operator. Terraform does not install Argo CD itself.
- `scripts/configure-argocd-from-terraform.py` writes the current region,
  cluster/secret prefix, VPC, and controller IRSA outputs to deployment
  manifests. Run it after apply and whenever those Terraform settings change,
  then review and commit the generated non-secret values.
- Kafka Connect CDC is intentionally not automatically deployed. It depends
  on application migrations and a PostgreSQL replication user/publication.
- Dev and staging overlays provide Kubernetes configuration, not separate
  Terraform-managed AWS environments.
- The managed-service architecture has significant costs; run a reviewed
  Terraform plan and estimate expected monthly spend before applying.
- Application dashboards, distributed tracing, cross-region disaster
  recovery, and a complete on-call program are not fully supplied here. The
  infrastructure dashboard, selected alarms, log collection, and recovery
  exercise instructions are included, but must be validated in a deployed AWS
  environment. See [OPERATIONS.md](OPERATIONS.md).
- AWS service versions, chart versions, GitHub Actions, and application image
  tags should be reviewed and updated through normal dependency and security
  maintenance.

## Contributing

Keep infrastructure and manifests validated, avoid embedding environment
secrets, and update [DEPLOYMENT.md](DEPLOYMENT.md) when bootstrap behavior or
operator steps change. Changes that alter AWS resources should include a
review of Terraform plan impact, security boundaries, availability, and cost.
