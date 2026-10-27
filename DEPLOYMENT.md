# Deployment

## What this repository provisions

Terraform provisions a private-subnet EKS cluster and a private PostgreSQL RDS
instance. The Kubernetes production overlay deploys the catalog and search
applications into `platform-production`; it expects Redis, Kafka, and
OpenSearch endpoints to be provided separately. The local Compose stack is for
development and is not a production substitute for those managed services.

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

3. Supply `cluster_version` and `db_password` as protected CI variables
   (`TF_VAR_cluster_version` and `TF_VAR_db_password`). Choose an EKS version
   currently supported in the selected region. Do not put credentials in
   `.tfvars` files committed to Git. Terraform state contains the RDS password
   and must remain encrypted and access-controlled.
4. Review and apply:

   ```sh
   terraform plan
   terraform apply
   ```

The EKS API endpoint is private-only, and the RDS security group accepts
PostgreSQL only from EKS worker nodes. Run Terraform and `kubectl` from a
network connected to the VPC. The RDS instance has deletion protection and
retained final snapshots; plan intentional teardown separately.

## GitOps prerequisites

Before syncing the Argo CD root application:

1. Verify both GHCR package names and access. The app repositories
   publish `ghcr.io/jahrough/product-catalog` and
   `ghcr.io/jahrough/product-search`. The production Application configures
   Argo CD Image Updater to resolve `latest` to an image digest and write the
   digest pin back to Git. Confirm Image Updater is installed and configured
   with GHCR read access and narrowly scoped write access to this Git branch.
   For private packages, configure cluster image-pull credentials as well.
2. Before syncing workloads, create the `platform-production` namespace, then
   copy [platform-runtime-config.example.yaml](./kubernetes/overlays/prod/platform-runtime-config.example.yaml),
   replace all `REPLACE_WITH_*` values, and apply it. It defines
   `platform-runtime-config` with these keys:
   `DB_HOST` (RDS hostname only), `DB_PORT` (`5432`), `DB_NAME`
   (`product_catalog`), `REDIS_HOST`, `REDIS_PORT`, `KAFKA_BOOTSTRAP_SERVERS`,
   and `OPENSEARCH_URIS`. Set the service endpoints for your managed
   infrastructure; this repository does not provision Redis, Kafka, or
   OpenSearch for EKS. The catalog and search apps share this ConfigMap. The
   example is intentionally not included in the Kustomize resources, so
   placeholders cannot be accidentally deployed.
3. Create the `platform-db` Secret in `platform-production` through your
   secret-management controller. It must contain `username` and `password` for
   a least-privilege application database account (not the RDS master account),
   plus `url` (`jdbc:postgresql://<RDS hostname>:5432/product_catalog`) for the
   search service. The catalog service reads the same credentials as
   `DB_USER`/`DB_PASSWORD`; it constructs its JDBC URL from `DB_HOST`,
   `DB_PORT`, and `DB_NAME` in `platform-runtime-config`. Do not commit Secret
   values.
4. Install and configure Argo CD in the cluster and grant it read access to
   this Git repository. Bootstrap the root Application with
   `kubectl apply -f argocd/root-app.yaml`. It creates the production child
   Application, which syncs `kubernetes/overlays/prod`.

The app Services are cluster-internal `ClusterIP` Services. Configure an
Ingress/Gateway and DNS separately if the applications need external traffic.
The production HPA also requires the Kubernetes Metrics API.

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
