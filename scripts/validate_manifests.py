#!/usr/bin/env python3
import subprocess
import sys


def run(*command):
    subprocess.run(command, check=True)


for environment in ("dev", "staging", "prod"):
    run("kubectl", "kustomize", f"kubernetes/overlays/{environment}")

run("kubectl", "kustomize", "kubernetes/cluster-config")
run("docker", "compose", "-f", "compose/compose.yml", "-f",
    "compose/compose.apps.yaml", "config", "--quiet")
print("Kubernetes and Compose manifests validated.")