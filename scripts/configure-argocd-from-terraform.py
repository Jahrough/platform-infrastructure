#!/usr/bin/env python3
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_DIR = ROOT / "terraform"
FILES = (
    ROOT / "argocd/apps/external-secrets-app.yaml",
    ROOT / "argocd/apps/aws-load-balancer-controller-app.yaml",
    ROOT / "kubernetes/cluster-config/cluster-secret-store.yaml",
    ROOT / "kubernetes/overlays/prod/platform-runtime-config.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-cache-auth.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-catalog-db.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-search-db.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-cdc-db.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/cdc/platform-cdc-db.external-secret.yaml",
)


def terraform_output():
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=TERRAFORM_DIR,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def output_value(outputs, name):
    try:
        value = outputs[name]["value"]
    except (KeyError, TypeError) as error:
        raise SystemExit(f"Required Terraform output is missing: {name}") from error
    if not isinstance(value, str) or not value:
        raise SystemExit(f"Terraform output {name} must be a non-empty string.")
    return value


def main():
    outputs = terraform_output()
    values = {
        "__EXTERNAL_SECRETS_IRSA_ROLE_ARN__": output_value(
            outputs, "external_secrets_irsa_role_arn"
        ),
        "__LOAD_BALANCER_CONTROLLER_IRSA_ROLE_ARN__": output_value(
            outputs, "load_balancer_controller_irsa_role_arn"
        ),
        "__EKS_CLUSTER_NAME__": output_value(outputs, "eks_cluster_name"),
        "__AWS_REGION__": output_value(outputs, "aws_region"),
        "__VPC_ID__": output_value(outputs, "vpc_id"),
        "__CLUSTER_NAME__": output_value(outputs, "cluster_name"),
    }

    for path in FILES:
        content = path.read_text()
        for token, value in values.items():
            content = content.replace(token, value)

        if path.name == "external-secrets-app.yaml":
            content = re.sub(
                r"(?m)^(\s*eks\.amazonaws\.com/role-arn:\s*)[^\s]+$",
                rf"\g<1>{values['__EXTERNAL_SECRETS_IRSA_ROLE_ARN__']}",
                content,
            )
        elif path.name == "aws-load-balancer-controller-app.yaml":
            substitutions = (
                (r"clusterName:", values["__EKS_CLUSTER_NAME__"]),
                (r"region:", values["__AWS_REGION__"]),
                (r"vpcId:", values["__VPC_ID__"]),
                (
                    r"eks\.amazonaws\.com/role-arn:",
                    values["__LOAD_BALANCER_CONTROLLER_IRSA_ROLE_ARN__"],
                ),
            )
            for key, value in substitutions:
                content = re.sub(
                    rf"(?m)^(\s*{key}\s*)[^\s]+$",
                    rf"\g<1>{value}",
                    content,
                )
        elif path.name == "cluster-secret-store.yaml":
            content = re.sub(
                r"(?m)^(\s*region:\s*)[^\s]+$",
                rf"\g<1>{values['__AWS_REGION__']}",
                content,
            )
        else:
            content = re.sub(
                r"(?m)^(\s*key:\s*)[^/\s]+(/(?:platform|redis)/)",
                rf"\g<1>{values['__CLUSTER_NAME__']}\2",
                content,
            )

        if "__" in content and re.search(r"__[A-Z][A-Z0-9_]+__", content):
            raise SystemExit(f"Unresolved deployment token remains in {path}.")
        if content != path.read_text():
            path.write_text(content)
            print(f"Configured {path.relative_to(ROOT)}")

    print("Review and commit the generated non-secret Argo CD configuration.")


if __name__ == "__main__":
    main()
