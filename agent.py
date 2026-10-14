#!/usr/bin/env python3
"""Create a prompt agent in Azure AI Foundry, or add a version to an existing one.

Agents are not ARM resources - they exist only on the Foundry project data plane, so
they cannot be deployed with Bicep. This script is the one piece the template cannot
cover.

It reads the deployment outputs, so there is nothing to copy by hand.

Usage:
    python agent.py
    python agent.py --deployment ai-gateway --name my-agent
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

import requests
from azure.identity import AzureCliCredential

API_VERSION = "v1"
SCOPE = "https://ai.azure.com/.default"


def deployment_outputs(*args: str) -> dict[str, str]:
    """Read the outputs of a Bicep deployment, e.g. ("sub", "show", "--name", "ai-gateway")."""
    result = subprocess.run(
        ["az", "deployment", *args, "--query", "properties.outputs", "-o", "json"],
        capture_output=True,
        text=True,
        shell=(sys.platform == "win32"),
    )
    if result.returncode != 0:
        sys.exit(f"Could not read deployment ({' '.join(args)}).\n{result.stderr.strip()}")
    return {k: v["value"] for k, v in json.loads(result.stdout).items()}


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a Foundry prompt agent.")
    parser.add_argument("--deployment", default="ai-gateway", help="Name of the Bicep deployment.")
    parser.add_argument("--name", default="gateway-agent", help="Agent name.")
    parser.add_argument(
        "--instructions",
        default="You are a concise assistant. Answer in one short sentence.",
        help="System instructions for the agent.",
    )
    parser.add_argument(
        "--direct",
        action="store_true",
        help="Call the model deployment directly, bypassing the AI Gateway.",
    )
    args = parser.parse_args()

    out = deployment_outputs("sub", "show", "--name", args.deployment)
    account = out["accountName"]
    project = out["projectName"]
    connection = out["connectionName"]
    # The model the gateway connection serves. Read from the association module's own
    # deployment: it stays current when that module is redeployed alone, the
    # subscription-level outputs don't.
    deployment_name = deployment_outputs(
        "group", "show", "--resource-group", out["resourceGroupName"], "--name", "association"
    )["deploymentName"]

    # "<connection>/<deployment>" routes through the AI Gateway.
    # A bare "<deployment>" calls the model directly.
    model = deployment_name if args.direct else f"{connection}/{deployment_name}"

    token = AzureCliCredential().get_token(SCOPE).token
    url = (
        f"https://{account}.services.ai.azure.com/api/projects/{project}"
        f"/agents/{args.name}/versions?api-version={API_VERSION}"
    )
    body = {
        "description": "Created by agent.py",
        "definition": {
            "kind": "prompt",
            "model": model,
            "instructions": args.instructions,
            "tools": [],
        },
    }

    print(f"POST {url}")
    print(json.dumps(body, indent=2))

    # POST /agents/<name>/versions creates the agent, or adds a version to it.
    # POST /agents returns 409 once the agent exists; PUT returns 405.
    response = requests.post(
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=body,
        timeout=60,
    )

    if not response.ok:
        print(f"\nHTTP {response.status_code}\n{response.text}", file=sys.stderr)
        return 1

    version = response.json()
    print(f"\nCreated '{version['name']}' v{version['version']}")
    print(f"  model    : {version['definition']['model']}")
    print(f"  identity : {version['instance_identity']['principal_id']}")
    print(f"\nOpen the project in https://ai.azure.com to chat with it.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
