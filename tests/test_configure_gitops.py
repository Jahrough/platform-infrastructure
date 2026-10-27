import importlib
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
configure = importlib.import_module("configure-argocd-from-terraform")


def terraform_values(suffix):
    return {
        "external_secrets_irsa_role_arn": {"value": f"arn:aws:iam::123:role/eso-{suffix}"},
        "load_balancer_controller_irsa_role_arn": {
            "value": f"arn:aws:iam::123:role/alb-{suffix}"
        },
        "eks_cluster_name": {"value": f"cluster-{suffix}"},
        "aws_region": {"value": "us-west-2"},
        "vpc_id": {"value": f"vpc-{suffix}"},
        "runtime_config_secret_arn": {
            "value": f"arn:aws:secretsmanager:us-west-2:123:secret:runtime-{suffix}"
        },
        "redis_auth_secret_arn": {
            "value": f"arn:aws:secretsmanager:us-west-2:123:secret:redis-{suffix}"
        },
        "app_database_secret_name": {"value": f"app-db-{suffix}"},
        "search_database_secret_name": {"value": f"search-db-{suffix}"},
        "cdc_database_secret_name": {"value": f"cdc-db-{suffix}"},
    }


class ConfigureGitOpsTests(unittest.TestCase):
    def test_generates_and_refreshes_nonsecret_integration_values(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            files = {
                "argocd/apps/external-secrets.yaml": (
                    "eks.amazonaws.com/role-arn: REPLACE_ME_WITH_TERRAFORM_IRSA_ROLE_ARN\n"
                ),
                "argocd/apps/aws-load-balancer-controller.yaml": (
                    "clusterName: REPLACE_ME_WITH_EKS_CLUSTER_NAME\n"
                    "region: REPLACE_ME_WITH_AWS_REGION\n"
                    "vpcId: REPLACE_ME_WITH_VPC_ID\n"
                    "eks.amazonaws.com/role-arn: REPLACE_ME_WITH_LOAD_BALANCER_CONTROLLER_IRSA_ROLE_ARN\n"
                ),
                "kubernetes/platform/providers/aws/cluster-secret-store.yaml": (
                    "region: REPLACE_ME_WITH_TERRAFORM_AWS_REGION\n"
                ),
                "charts/spring-service/values/environments/production.yaml": (
                    "externalSecrets:\n"
                    "  runtimeConfig:\n"
                    "    remoteKey: REPLACE_ME_WITH_PRODUCTION_RUNTIME_CONFIG_SECRET_NAME\n"
                    "  cacheAuth:\n"
                    "    remoteKey: REPLACE_ME_WITH_PRODUCTION_CACHE_AUTH_SECRET_NAME\n"
                    "  database:\n"
                    "    remoteKeys:\n"
                    "      product-catalog: REPLACE_ME_WITH_PRODUCTION_CATALOG_DB_SECRET_NAME\n"
                    "      product-search: REPLACE_ME_WITH_PRODUCTION_SEARCH_DB_SECRET_NAME\n"
                ),
                "kubernetes/platform/cdc/platform-cdc-db.external-secret.yaml": (
                    "data:\n"
                    "  - remoteRef:\n"
                    "      key: REPLACE_ME_WITH_PRODUCTION_CDC_DB_SECRET_NAME\n"
                    "  - remoteRef:\n"
                    "      key: REPLACE_ME_WITH_PRODUCTION_CDC_DB_SECRET_NAME\n"
                ),
                "kubernetes/platform/cdc/platform-runtime-config.external-secret.yaml": (
                    "data:\n"
                    "  - remoteRef:\n"
                    "      key: REPLACE_ME_WITH_PRODUCTION_RUNTIME_CONFIG_SECRET_NAME\n"
                    "  - remoteRef:\n"
                    "      key: REPLACE_ME_WITH_PRODUCTION_RUNTIME_CONFIG_SECRET_NAME\n"
                ),
            }
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)

            configure.configure_gitops(root, terraform_values("a"))
            production = (root / "charts/spring-service/values/environments/production.yaml").read_text()
            self.assertIn('"app-db-a"', production)
            self.assertIn('"search-db-a"', production)
            self.assertIn("secret:runtime-a", production)
            self.assertIn("role/eso-a", (root / "argocd/apps/external-secrets.yaml").read_text())

            configure.configure_gitops(root, terraform_values("b"))
            production = (root / "charts/spring-service/values/environments/production.yaml").read_text()
            self.assertIn('"app-db-b"', production)
            self.assertIn("secret:runtime-b", production)
            self.assertIn("cluster-b", (root / "argocd/apps/aws-load-balancer-controller.yaml").read_text())
            self.assertNotIn("REPLACE_ME", "\n".join(path.read_text() for path in root.rglob("*.yaml")))


if __name__ == "__main__":
    unittest.main()
