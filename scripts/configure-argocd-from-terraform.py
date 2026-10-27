#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_DIR = ROOT / "terraform"
DEFAULT_GITOPS_REPO = ROOT.parent / "platform-gitops"


def terraform_output(terraform_dir=TERRAFORM_DIR):
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=terraform_dir,
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


def set_line_value(content, key, value):
    pattern = re.compile(rf"(?m)^(\s*{re.escape(key)}:\s*).+$")
    updated, count = pattern.subn(lambda match: match.group(1) + value, content)
    if count != 1:
        raise ValueError(f"Expected exactly one {key} setting.")
    return updated


def set_line_values(content, key, value, expected):
    pattern = re.compile(rf"(?m)^(\s*{re.escape(key)}:\s*).+$")
    updated, count = pattern.subn(lambda match: match.group(1) + value, content)
    if count != expected:
        raise ValueError(f"Expected exactly {expected} {key} settings.")
    return updated


def set_nested_scalar(content, path, value):
    lines = content.splitlines(keepends=True)
    parent_indices = [None]
    parent_indent = -2
    for section in path[:-1]:
        target_indent = parent_indent + 2
        match_index = None
        previous_index = parent_indices[-1]
        start = 0 if previous_index is None else previous_index + 1
        for index in range(start, len(lines)):
            line = lines[index]
            if line.strip() and len(line) - len(line.lstrip()) <= parent_indent:
                break
            match = re.match(r"^(\s*)([^:#]+):\s*(?:#.*)?$", line.rstrip("\n"))
            if match and len(match.group(1)) == target_indent and match.group(2).strip() == section:
                match_index = index
                break
        if match_index is None:
            raise ValueError(f"Could not locate section {'/'.join(path[:-1])}.")
        parent_indices.append(match_index)
        parent_indent = target_indent

    target_indent = parent_indent + 2
    start = parent_indices[-1] + 1
    for index in range(start, len(lines)):
        line = lines[index]
        if line.strip() and len(line) - len(line.lstrip()) <= parent_indent:
            break
        match = re.match(r"^(\s*)([^:#]+):.*$", line.rstrip("\n"))
        if match and len(match.group(1)) == target_indent and match.group(2).strip() == path[-1]:
            ending = "\n" if line.endswith("\n") else ""
            lines[index] = f"{match.group(1)}{path[-1]}: {value}{ending}"
            return "".join(lines)
    raise ValueError(f"Could not locate setting {'/'.join(path)}.")


def configure_gitops(gitops_repo, outputs):
    values = {
        "external_secrets_irsa_role_arn": output_value(
            outputs, "external_secrets_irsa_role_arn"
        ),
        "load_balancer_controller_irsa_role_arn": output_value(
            outputs, "load_balancer_controller_irsa_role_arn"
        ),
        "eks_cluster_name": output_value(outputs, "eks_cluster_name"),
        "aws_region": output_value(outputs, "aws_region"),
        "vpc_id": output_value(outputs, "vpc_id"),
        "runtime_config_secret_arn": output_value(outputs, "runtime_config_secret_arn"),
        "redis_auth_secret_arn": output_value(outputs, "redis_auth_secret_arn"),
        "app_database_secret_name": output_value(outputs, "app_database_secret_name"),
        "search_database_secret_name": output_value(outputs, "search_database_secret_name"),
        "cdc_database_secret_name": output_value(outputs, "cdc_database_secret_name"),
    }

    targets = {
        "external_secrets": gitops_repo / "argocd/apps/external-secrets.yaml",
        "load_balancer": gitops_repo / "argocd/apps/aws-load-balancer-controller.yaml",
        "secret_store": gitops_repo / "kubernetes/platform/providers/aws/cluster-secret-store.yaml",
        "production_values": gitops_repo / "charts/spring-service/values/environments/production.yaml",
        "cdc_database": gitops_repo / "kubernetes/platform/cdc/platform-cdc-db.external-secret.yaml",
        "cdc_runtime": gitops_repo / "kubernetes/platform/cdc/platform-runtime-config.external-secret.yaml",
    }
    missing = [path for path in targets.values() if not path.is_file()]
    if missing:
        raise SystemExit(f"GitOps configuration file is missing: {missing[0]}")

    updates = {}
    content = targets["external_secrets"].read_text()
    updates[targets["external_secrets"]] = set_line_value(
        content, "eks.amazonaws.com/role-arn", values["external_secrets_irsa_role_arn"]
    )

    content = targets["load_balancer"].read_text()
    for key, value in (
        ("clusterName", values["eks_cluster_name"]),
        ("region", values["aws_region"]),
        ("vpcId", values["vpc_id"]),
        ("eks.amazonaws.com/role-arn", values["load_balancer_controller_irsa_role_arn"]),
    ):
        content = set_line_value(content, key, value)
    updates[targets["load_balancer"]] = content

    content = targets["secret_store"].read_text()
    updates[targets["secret_store"]] = set_line_value(
        content, "region", values["aws_region"]
    )

    content = targets["production_values"].read_text()
    for path, value in (
        (("externalSecrets", "runtimeConfig", "remoteKey"), values["runtime_config_secret_arn"]),
        (("externalSecrets", "cacheAuth", "remoteKey"), values["redis_auth_secret_arn"]),
        (("externalSecrets", "database", "remoteKeys", "product-catalog"), values["app_database_secret_name"]),
        (("externalSecrets", "database", "remoteKeys", "product-search"), values["search_database_secret_name"]),
    ):
        content = set_nested_scalar(content, path, json.dumps(value))
    updates[targets["production_values"]] = content

    for target_name, secret_name in (
        ("cdc_database", values["cdc_database_secret_name"]),
        ("cdc_runtime", values["runtime_config_secret_arn"]),
    ):
        content = targets[target_name].read_text()
        updates[targets[target_name]] = set_line_values(
            content, "key", json.dumps(secret_name), 2
        )

    for path, content in updates.items():
        if "REPLACE_ME" in content or re.search(r"__[A-Z][A-Z0-9_]+__", content):
            raise SystemExit(f"Unresolved deployment placeholder remains in {path}.")
    for path, content in updates.items():
        if content != path.read_text():
            path.write_text(content)
            print(f"Configured {path.relative_to(gitops_repo)}")


def main():
    parser = argparse.ArgumentParser(
        description="Configure GitOps AWS integrations from Terraform outputs."
    )
    parser.add_argument(
        "--gitops-repo",
        type=Path,
        default=DEFAULT_GITOPS_REPO,
        help="Path to the platform-gitops checkout (default: sibling checkout).",
    )
    args = parser.parse_args()
    if not args.gitops_repo.is_dir():
        parser.error(f"GitOps repository directory does not exist: {args.gitops_repo}")

    outputs = terraform_output()
    try:
        configure_gitops(args.gitops_repo, outputs)
    except ValueError as error:
        parser.error(str(error))
    print("Review and commit the generated non-secret GitOps configuration.")


if __name__ == "__main__":
    main()
