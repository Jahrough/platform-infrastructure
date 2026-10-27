# Deployment

## Platform components and cost

Terraform provisions a three-AZ VPC (one NAT gateway per AZ), private EKS,
Multi-AZ PostgreSQL RDS, three-broker MSK, encrypted Multi-AZ Redis, and a
three-node VPC OpenSearch domain. It also configures External Secrets access,
CloudWatch logs/metrics, alarms, and IAM roles for External Secrets and the AWS
Load Balancer Controller. These are production-oriented managed-service
defaults with significant ongoing AWS cost; review instance sizing and
regional support before applying.

The production Kustomize overlay deploys the product applications and
autoscaling/disruption resources. Kafka Connect is a separate, manually
synced Argo CD application so it can be brought up after the outbox schema and
replication account exist. The ingress manifest remains a template until a
real domain and ACM certificate are selected.

## Terraform

1. Create an encrypted, versioned S3 bucket for Terraform state. Keep its public
   access blocked and grant access only to the deployment identity.
2. From `terraform/`, initialize the S3 backend with the bucket and a unique
   key, for example:

   ```sh
   terraform init \
     -backend-config="bucket=YOUR_STATE_BUCKET" \
     -backend-config="key=platform-infrastructure/terraform.tfstate" \
     -backend-config="region=us-east-1" \
     -backend-config="encrypt=true" \
     -backend-config="use_lockfile=true"
   ```

3. Supply `cluster_version` as `TF_VAR_cluster_version`; choose an EKS version
   currently supported in the selected region. Terraform uses RDS-managed
   master credentials. The state backend must still be encrypted and
   access-controlled.
4. Review and apply:

   ```sh
   terraform plan
   terraform apply
   ```

The EKS API endpoint is private-only, and the RDS security group accepts
PostgreSQL only from EKS worker nodes. Run Terraform and `kubectl` from a
network connected to the VPC. RDS logical replication and forced TLS require a
parameter-group reboot before CDC setup. The RDS, Redis, and OpenSearch
resources have deletion safeguards; plan intentional teardown separately.

### GitHub Actions

`Validate infrastructure` checks Terraform formatting/validation, YAML,
Kustomize, Compose, connector JSON, and shell syntax on changes.
`Terraform deployment` is manual only. Configure the GitHub production
environment with required reviewers and these Actions variables:

- `TERRAFORM_AWS_ROLE_ARN`: least-privilege GitHub OIDC role for Terraform.
- `AWS_REGION`: deployment region (the current Kubernetes SecretStore uses
  `us-east-1`, so update it if you choose another region).
- `TF_STATE_BUCKET` and `TF_STATE_KEY`: encrypted, versioned S3 state location.
- `CLUSTER_VERSION`: supported EKS version.
- `ALERT_EMAIL`: optional alarm subscription address.

The Kubernetes SecretStore region and ExternalSecret remote keys must match
Terraform. The manifests currently target `us-east-1` and the default
`product-catalog-cluster` name; if you override either Terraform variable,
update `kubernetes/cluster-config/cluster-secret-store.yaml` and the
`remoteRef.key` values under `kubernetes/overlays/prod/` (including `cdc/`)
before syncing Argo CD.

The workflow plans by default. Choose `apply` only after reviewing the plan and
approving the protected production environment. The workflow never runs
automatically on a push.

## GitOps bootstrap

Before syncing the Argo CD root application:

1. Apply Terraform from a VPC-connected runner/operator and capture outputs:

   ```sh
   terraform output
   ```

2. Before application sync, create app database roles and Secrets Manager
   values. Run the bootstrap script from a network that can reach RDS, using
   the output secret ARN and names:

   ```sh
   bash scripts/bootstrap-app-databases.sh \
     "$(terraform -chdir=terraform output -raw rds_endpoint)" \
     "$(terraform -chdir=terraform output -raw rds_master_secret_arn)" \
     "$(terraform -chdir=terraform output -raw app_database_secret_name)" \
     "$(terraform -chdir=terraform output -raw search_database_secret_name)" \
     us-east-1
   ```

   It prompts for per-service passwords, creates the least-privilege catalog
   and search roles/database, and stores the credentials in Secrets Manager.
   The generated DB credentials are not printed or committed.
3. Install/configure Argo CD in the EKS cluster and grant read access to this
   repository. In `argocd/apps/external-secrets-app.yaml`, replace the IRSA
   role placeholder with Terraform's `external_secrets_irsa_role_arn` output.
   In `argocd/apps/aws-load-balancer-controller-app.yaml`, replace the role,
   VPC, cluster name, and region placeholders with Terraform outputs/variables.
   These manifests are watched by the root Application.
4. Bootstrap the root Application:

   ```sh
   kubectl apply -f argocd/root-app.yaml
   ```

   The app-of-apps creates External Secrets Operator, the AWS Load Balancer
   Controller, Metrics Server, a ClusterSecretStore, and the production
   workload Application.
   The production runtime config, Redis token, and DB credentials are synced
   from Secrets Manager into Kubernetes. Ensure Argo Image Updater is installed
   and has GHCR read access and narrowly scoped Git write access; the images
   are `ghcr.io/jahrough/product-catalog` and
   `ghcr.io/jahrough/product-search`.
5. To expose the apps, obtain an ACM certificate for a real DNS domain, replace
   the host and certificate placeholders in
   `kubernetes/overlays/prod/ingress.example.yaml`, then add that manifest to
   the production Kustomization and commit it. Create Route 53 aliases for the
   resulting ALB. No hostname is guessed or deployed by default.
6. After the catalog migrations have created `public.outbox`, set up the CDC
   database role and credential:

   ```sh
   bash scripts/bootstrap-cdc-user.sh \
     "$(terraform -chdir=terraform output -raw rds_endpoint)" \
     "$(terraform -chdir=terraform output -raw rds_master_secret_arn)" \
     "$(terraform -chdir=terraform output -raw cdc_database_secret_name)" \
     us-east-1
   ```

   Then manually sync the `product-cdc` Argo CD Application and register the
   connector from a machine that can reach its internal REST service:

   ```sh
   bash scripts/register-outbox-connector.sh
   ```

The `rds.logical_replication` parameter requires a reboot before running the
CDC bootstrap script. The application and Connect Services are internal
`ClusterIP`s. Metrics Server supplies the EKS Metrics API for HPA; the EKS
CloudWatch Observability add-on ships cluster logs and container metrics to
CloudWatch. Configure
CloudWatch alarm email subscriptions by confirming the SNS email request.

## Local Compose

Set `POSTGRES_PASSWORD` in the environment, then run both Compose files
together so the applications and their dependencies share one project:

```sh
export POSTGRES_PASSWORD='use-a-local-development-password'
docker compose -f compose/compose.yml -f compose/compose.apps.yaml up --build
```

The local OpenSearch service has its security plugin disabled and must not be
exposed outside a trusted development machine; all published local ports are
bound to loopback. The connector configuration uses Kafka Connect's
environment variable config provider for the password.
