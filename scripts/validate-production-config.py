#!/usr/bin/env python3
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG_FILES = (
    ROOT / "argocd/apps/external-secrets-app.yaml",
    ROOT / "argocd/apps/aws-load-balancer-controller-app.yaml",
    ROOT / "kubernetes/cluster-config/cluster-secret-store.yaml",
    ROOT / "kubernetes/overlays/prod/platform-runtime-config.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-cache-auth.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-catalog-db.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-search-db.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/platform-cdc-db.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/cdc/platform-cdc-db.external-secret.yaml",
    ROOT / "kubernetes/overlays/prod/kustomization.yaml",
    ROOT / "kubernetes/overlays/prod/cdc/kustomization.yaml",
)


def main():
    failures = []
    for path in CONFIG_FILES:
        content = path.read_text()
        if re.search(r"__[A-Z][A-Z0-9_]+__", content):
            failures.append(f"Unresolved Terraform configuration token in {path.relative_to(ROOT)}")
        if "REPLACE_WITH_" in content:
            failures.append(f"Unresolved deployment placeholder in {path.relative_to(ROOT)}")

    for path in (
        ROOT / "kubernetes/overlays/prod/kustomization.yaml",
        ROOT / "kubernetes/overlays/prod/cdc/kustomization.yaml",
    ):
        if re.search(r"(?m)^\s+digest:\s*sha256:0{64}\s*$", path.read_text()):
            failures.append(
                f"Replace the fail-closed image digest in {path.relative_to(ROOT)}"
            )

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Production configuration has no unresolved tokens or placeholder image digests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
