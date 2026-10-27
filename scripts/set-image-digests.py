#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PINS = {
    "catalog": (
        ROOT / "kubernetes/overlays/prod/kustomization.yaml",
        "ghcr.io/jahrough/product-catalog",
    ),
    "search": (
        ROOT / "kubernetes/overlays/prod/kustomization.yaml",
        "ghcr.io/jahrough/product-search",
    ),
    "connect": (
        ROOT / "kubernetes/overlays/prod/cdc/kustomization.yaml",
        "ghcr.io/jahrough/platform-infrastructure/kafka-connect",
    ),
}


def valid_digest(value):
    return re.fullmatch(r"sha256:[0-9a-f]{64}", value) is not None


def main():
    parser = argparse.ArgumentParser(
        description="Set immutable production image digests in Kustomize overlays."
    )
    for name in PINS:
        parser.add_argument(f"--{name}-digest", required=True, help="sha256:<64 hex chars>")
    args = parser.parse_args()

    for name, (path, image) in PINS.items():
        digest = getattr(args, f"{name}_digest")
        if not valid_digest(digest) or digest.endswith("0" * 64):
            parser.error(f"--{name}-digest must be a real sha256 digest.")

        content = path.read_text()
        pattern = re.compile(
            rf"(?m)^(\s+- name: {re.escape(image)}\n\s+digest:\s*)sha256:[0-9a-f]{{64}}$"
        )
        updated, count = pattern.subn(rf"\g<1>{digest}", content)
        if count != 1:
            parser.error(f"Expected exactly one digest pin for {image} in {path}.")
        path.write_text(updated)
        print(f"Pinned {image} to {digest}")

    print("Review and commit the immutable production image pins.")


if __name__ == "__main__":
    main()
