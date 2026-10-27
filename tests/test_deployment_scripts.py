import contextlib
import importlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

configure = importlib.import_module("configure-argocd-from-terraform")
pin_images = importlib.import_module("set-image-digests")
enable_ingress = importlib.import_module("enable-ingress")


class ConfigureArgoCdTests(unittest.TestCase):
    def test_generates_and_refreshes_infrastructure_values(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            configure.ROOT = root.parent
            external_secrets = root / "external-secrets-app.yaml"
            load_balancer = root / "aws-load-balancer-controller-app.yaml"
            secret_store = root / "cluster-secret-store.yaml"
            runtime_secret = root / "platform-runtime-config.external-secret.yaml"
            external_secrets.write_text(
                "eks.amazonaws.com/role-arn: __EXTERNAL_SECRETS_IRSA_ROLE_ARN__\n"
            )
            load_balancer.write_text(
                "clusterName: __EKS_CLUSTER_NAME__\n"
                "region: __AWS_REGION__\n"
                "vpcId: __VPC_ID__\n"
                "eks.amazonaws.com/role-arn: __LOAD_BALANCER_CONTROLLER_IRSA_ROLE_ARN__\n"
            )
            secret_store.write_text("region: __AWS_REGION__\n")
            runtime_secret.write_text(
                "remoteRef:\n  key: __CLUSTER_NAME__/platform/runtime-config\n"
            )
            configure.FILES = (
                external_secrets,
                load_balancer,
                secret_store,
                runtime_secret,
            )

            def terraform_values(cluster, region, suffix):
                return {
                    "external_secrets_irsa_role_arn": {"value": f"arn:aws:iam::123:role/eso-{suffix}"},
                    "load_balancer_controller_irsa_role_arn": {
                        "value": f"arn:aws:iam::123:role/alb-{suffix}"
                    },
                    "eks_cluster_name": {"value": cluster},
                    "aws_region": {"value": region},
                    "vpc_id": {"value": f"vpc-{suffix}"},
                    "cluster_name": {"value": cluster},
                }

            with patch.object(configure, "terraform_output", return_value=terraform_values("cluster-a", "us-west-2", "a")):
                configure.main()
            self.assertIn("cluster-a/platform/runtime-config", runtime_secret.read_text())
            self.assertIn("vpc-a", load_balancer.read_text())
            self.assertIn("us-west-2", secret_store.read_text())

            with patch.object(configure, "terraform_output", return_value=terraform_values("cluster-b", "eu-west-1", "b")):
                configure.main()
            self.assertIn("cluster-b/platform/runtime-config", runtime_secret.read_text())
            self.assertIn("cluster-b", load_balancer.read_text())
            self.assertIn("eu-west-1", secret_store.read_text())


class ImagePinTests(unittest.TestCase):
    def test_replaces_all_image_pins_with_immutable_digests(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            prod = root / "prod.yaml"
            cdc = root / "cdc.yaml"
            prod.write_text(
                "images:\n"
                "  - name: ghcr.io/jahrough/product-catalog\n"
                "    digest: sha256:" + "0" * 64 + "\n"
                "  - name: ghcr.io/jahrough/product-search\n"
                "    digest: sha256:" + "0" * 64 + "\n"
            )
            cdc.write_text(
                "images:\n"
                "  - name: ghcr.io/jahrough/platform-infrastructure/kafka-connect\n"
                "    digest: sha256:" + "0" * 64 + "\n"
            )
            pin_images.PINS = {
                "catalog": (prod, "ghcr.io/jahrough/product-catalog"),
                "search": (prod, "ghcr.io/jahrough/product-search"),
                "connect": (cdc, "ghcr.io/jahrough/platform-infrastructure/kafka-connect"),
            }
            digests = {
                "catalog": "1" * 64,
                "search": "2" * 64,
                "connect": "3" * 64,
            }
            args = ["set-image-digests.py"]
            for name, digest in digests.items():
                args.extend((f"--{name}-digest", f"sha256:{digest}"))

            with patch.object(sys, "argv", args):
                pin_images.main()

            self.assertIn("sha256:" + digests["catalog"], prod.read_text())
            self.assertIn("sha256:" + digests["search"], prod.read_text())
            self.assertIn("sha256:" + digests["connect"], cdc.read_text())

    def test_rejects_malformed_digest(self):
        with patch.object(
            sys,
            "argv",
            [
                "set-image-digests.py",
                "--catalog-digest",
                "latest",
                "--search-digest",
                "sha256:" + "2" * 64,
                "--connect-digest",
                "sha256:" + "3" * 64,
            ],
        ), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            pin_images.main()


class EnableIngressTests(unittest.TestCase):
    def test_renders_and_adds_ingress_to_kustomize(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            overlay = Path(temp_dir)
            template = overlay / "ingress.example.yaml"
            output = overlay / "ingress.yaml"
            kustomization = overlay / "kustomization.yaml"
            template.write_text((ROOT / "kubernetes/overlays/prod/ingress.example.yaml").read_text())
            kustomization.write_text(
                "resources:\n  - ../../base\nimages:\n  - name: example\nnamespace: platform-production\n"
            )
            enable_ingress.OVERLAY = overlay
            enable_ingress.ROOT = overlay.parent
            enable_ingress.TEMPLATE = template
            enable_ingress.OUTPUT = output
            enable_ingress.KUSTOMIZATION = kustomization
            with patch.object(
                sys,
                "argv",
                [
                    "enable-ingress.py",
                    "--domain",
                    "example.com",
                    "--certificate-arn",
                    "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000",
                    "--region",
                    "us-east-1",
                    "--scheme",
                    "internal",
                ],
            ):
                enable_ingress.main()

            rendered = output.read_text()
            self.assertIn("catalog.example.com", rendered)
            self.assertIn("search.example.com", rendered)
            self.assertIn("scheme: internal", rendered)
            self.assertIn("certificate/00000000-0000-0000-0000-000000000000", rendered)
            self.assertIn("  - ingress.yaml", kustomization.read_text())

    def test_rejects_certificate_from_another_region(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            overlay = Path(temp_dir)
            enable_ingress.OVERLAY = overlay
            enable_ingress.ROOT = overlay.parent
            enable_ingress.TEMPLATE = overlay / "ingress.example.yaml"
            enable_ingress.OUTPUT = overlay / "ingress.yaml"
            enable_ingress.KUSTOMIZATION = overlay / "kustomization.yaml"
            enable_ingress.TEMPLATE.write_text("spec: {}\n")
            enable_ingress.KUSTOMIZATION.write_text("resources:\n  - base\nimages: []\n")
            with patch.object(
                sys,
                "argv",
                [
                    "enable-ingress.py",
                    "--domain",
                    "example.com",
                    "--certificate-arn",
                    "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000",
                    "--region",
                    "us-west-2",
                ],
            ), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                enable_ingress.main()
            self.assertFalse(enable_ingress.OUTPUT.exists())


if __name__ == "__main__":
    unittest.main()
