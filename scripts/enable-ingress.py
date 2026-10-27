#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / "kubernetes/overlays/prod"
TEMPLATE = OVERLAY / "ingress.example.yaml"
OUTPUT = OVERLAY / "ingress.yaml"
KUSTOMIZATION = OVERLAY / "kustomization.yaml"


def main():
    parser = argparse.ArgumentParser(
        description="Render and enable the production ALB Ingress template."
    )
    parser.add_argument("--domain", required=True, help="DNS zone, e.g. example.com")
    parser.add_argument("--certificate-arn", required=True, help="Regional ACM certificate ARN")
    parser.add_argument(
        "--scheme",
        choices=("internet-facing", "internal"),
        default="internet-facing",
        help="ALB exposure scheme (default: internet-facing)",
    )
    parser.add_argument("--region", required=True, help="AWS region containing the certificate")
    args = parser.parse_args()

    if not re.fullmatch(r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}", args.domain):
        parser.error("--domain must be a valid DNS zone name without a hostname prefix.")
    arn_pattern = (
        rf"^arn:aws(?:-[a-z0-9]+)*:acm:{re.escape(args.region)}:"
        r"\d{12}:certificate/[0-9a-fA-F-]{36}$"
    )
    if not re.fullmatch(arn_pattern, args.certificate_arn):
        parser.error("--certificate-arn must identify a certificate in --region.")

    content = TEMPLATE.read_text()
    content = content.replace("REPLACE_WITH_ACM_CERTIFICATE_ARN", args.certificate_arn)
    content = content.replace("REPLACE_WITH_YOUR_DOMAIN", args.domain)
    content = content.replace("scheme: internet-facing", f"scheme: {args.scheme}")
    if "REPLACE_WITH_" in content:
        parser.error("Ingress template still contains unresolved placeholders.")

    existing_resources = KUSTOMIZATION.read_text()
    if OUTPUT.exists() and "ingress.yaml" in existing_resources:
        parser.error("Ingress is already enabled; edit ingress.yaml directly if needed.")
    add_resource = False
    if re.search(r"(?m)^\s+- ingress\.yaml\s*$", existing_resources) is None:
        insertion = re.search(r"(?m)^(?:images|namespace):", existing_resources)
        if insertion is None:
            parser.error("Could not locate the end of the Kustomize resources list.")
        existing_resources = (
            existing_resources[: insertion.start()]
            + "  - ingress.yaml\n\n"
            + existing_resources[insertion.start() :]
        )
        add_resource = True
    OUTPUT.write_text(content)
    if add_resource:
        KUSTOMIZATION.write_text(existing_resources)
    print(f"Created {OUTPUT.relative_to(ROOT)} and enabled it in the production overlay.")
    print("Create DNS aliases for the ALB after it is provisioned.")


if __name__ == "__main__":
    main()
