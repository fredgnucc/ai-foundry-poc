#!/usr/bin/env python3
"""Push this repo into a search index that Foundry IQ can use as a knowledge source.

Foundry IQ can't read GitHub, and a tenant policy keeps storage accounts off the public
network, so there is no blob container for Search to index. This script does the indexing
itself: it chunks the files tracked by git, embeds each chunk with the embedding deployment,
and pushes the chunks into an index on the search service. In the Foundry portal, that
index then becomes a knowledge source (see README).

Safe to re-run after every commit: the index is created or updated, chunks are replaced,
and the chunks of deleted or shortened files are removed.

Usage:
    python knowledge.py
    python knowledge.py --deployment ai-gateway --index repo-docs
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import sys
import time
from pathlib import Path

import requests
from azure.identity import AzureCliCredential

SEARCH_API_VERSION = "2026-04-01"
OPENAI_API_VERSION = "2024-10-21"
SEARCH_SCOPE = "https://search.azure.com/.default"
OPENAI_SCOPE = "https://cognitiveservices.azure.com/.default"

REPO = Path(__file__).resolve().parent
EXTENSIONS = (".md", ".bicep", ".kql", ".json", ".py", ".xml", ".txt")
MAX_CHARS = 2000  # about 500 tokens: one README section or one screen of code
EMBED_BATCH = 16
UPLOAD_BATCH = 100


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


def check(response: requests.Response) -> requests.Response:
    if not response.ok:
        sys.exit(f"{response.request.method} {response.url}\nHTTP {response.status_code}\n{response.text}")
    return response


def chunk(path: str, text: str) -> list[tuple[str, str]]:
    """Split a file into (title, content) pairs of at most MAX_CHARS.

    Markdown also splits at every heading outside code fences, and each chunk is titled
    with its section, so a question lands on the right README section, not the whole file.
    """
    markdown = path.endswith(".md")
    chunks: list[tuple[str, str]] = []
    title, lines, size, fenced = path, [], 0, False

    def flush() -> None:
        nonlocal lines, size
        body = "\n".join(lines).strip()
        if body:
            chunks.append((title, body))
        lines, size = [], 0

    for raw in text.splitlines():
        for line in (raw[i : i + MAX_CHARS] for i in range(0, max(len(raw), 1), MAX_CHARS)):
            if markdown and line.lstrip().startswith("```"):
                fenced = not fenced
            heading = markdown and not fenced and line.startswith("#")
            if heading or size + len(line) > MAX_CHARS:
                flush()
            if heading:
                title = f"{path} > {line.lstrip('#').strip()}"
            lines.append(line)
            size += len(line) + 1
    flush()
    return chunks


def embed(session: requests.Session, url: str, texts: list[str]) -> list[list[float]]:
    for _ in range(5):
        response = session.post(url, json={"input": texts}, timeout=120)
        if response.status_code != 429:
            break
        time.sleep(float(response.headers.get("retry-after", "10")))
    data = check(response).json()["data"]
    return [item["embedding"] for item in sorted(data, key=lambda item: item["index"])]


def index_definition(name: str, endpoint: str, deployment: str, dimensions: int) -> dict:
    text = {"type": "Edm.String", "searchable": True, "retrievable": True, "sortable": False, "facetable": False}
    return {
        "name": name,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True},
            {"name": "path", **text, "filterable": True},
            {"name": "title", **text, "filterable": False, "analyzer": "en.microsoft"},
            {"name": "content", **text, "filterable": False, "analyzer": "en.microsoft"},
            {
                "name": "content_vector",
                "type": "Collection(Edm.Single)",
                "searchable": True,
                "retrievable": False,
                "stored": False,
                "dimensions": dimensions,
                "vectorSearchProfile": "default",
            },
        ],
        "vectorSearch": {
            "algorithms": [{"name": "hnsw", "kind": "hnsw"}],
            # Vectorizes the question at query time. No apiKey and no authIdentity: Search
            # calls the model with its system identity. The deployment is named after the model.
            "vectorizers": [
                {
                    "name": "embedding",
                    "kind": "azureOpenAI",
                    "azureOpenAIParameters": {
                        "resourceUri": endpoint.rstrip("/"),
                        "deploymentId": deployment,
                        "modelName": deployment,
                    },
                }
            ],
            "profiles": [{"name": "default", "algorithm": "hnsw", "vectorizer": "embedding"}],
        },
        # Agentic retrieval requires a semantic configuration; the default one is used.
        "semantic": {
            "defaultConfiguration": "default",
            "configurations": [
                {
                    "name": "default",
                    "prioritizedFields": {
                        "titleField": {"fieldName": "title"},
                        "prioritizedContentFields": [{"fieldName": "content"}],
                        "prioritizedKeywordsFields": [{"fieldName": "path"}],
                    },
                }
            ],
        },
    }


def indexed_ids(session: requests.Session, url: str) -> set[str]:
    ids: set[str] = set()
    while True:
        body = {"search": "*", "select": "id", "orderby": "id", "top": 1000, "skip": len(ids)}
        page = check(session.post(url, json=body, timeout=60)).json()["value"]
        ids.update(doc["id"] for doc in page)
        if len(page) < 1000:
            return ids


def push(session: requests.Session, url: str, actions: list[dict]) -> None:
    for start in range(0, len(actions), UPLOAD_BATCH):
        results = check(session.post(url, json={"value": actions[start : start + UPLOAD_BATCH]}, timeout=120))
        failed = [r for r in results.json()["value"] if not r["status"]]
        if failed:
            sys.exit(f"{len(failed)} documents failed, first: {failed[0]}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Push the repo into a search index for Foundry IQ.")
    parser.add_argument("--deployment", default="ai-gateway", help="Name of the Bicep deployment.")
    parser.add_argument("--index", default="repo-docs", help="Search index name.")
    args = parser.parse_args()

    rg = deployment_outputs("sub", "show", "--name", args.deployment)["resourceGroupName"]
    out = deployment_outputs("group", "show", "--resource-group", rg, "--name", "knowledge")
    search = f"https://{out['searchName']}.search.windows.net"
    endpoint, deployment = out["embeddingEndpoint"], out["embeddingDeploymentName"]

    files = subprocess.run(["git", "ls-files"], cwd=REPO, capture_output=True, text=True, check=True).stdout.splitlines()
    docs = []
    for path in (f for f in files if f.endswith(EXTENSIONS)):
        text = (REPO / path).read_text(encoding="utf-8", errors="replace")
        for n, (title, content) in enumerate(chunk(path, text)):
            key = base64.urlsafe_b64encode(f"{path}#{n}".encode()).decode()
            docs.append({"id": key, "path": path, "title": title, "content": content})
    print(f"{len(docs)} chunks from {len({d['path'] for d in docs})} files")

    credential = AzureCliCredential()
    openai = requests.Session()
    openai.headers["Authorization"] = f"Bearer {credential.get_token(OPENAI_SCOPE).token}"
    embed_url = f"{endpoint.rstrip('/')}/openai/deployments/{deployment}/embeddings?api-version={OPENAI_API_VERSION}"
    for start in range(0, len(docs), EMBED_BATCH):
        batch = docs[start : start + EMBED_BATCH]
        vectors = embed(openai, embed_url, [f"{d['title']}\n\n{d['content']}" for d in batch])
        for doc, vector in zip(batch, vectors):
            doc["content_vector"] = vector
    print(f"embedded with {deployment} ({len(docs[0]['content_vector'])} dimensions)")

    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {credential.get_token(SEARCH_SCOPE).token}"
    index = f"{search}/indexes/{args.index}"
    q = f"?api-version={SEARCH_API_VERSION}"
    definition = index_definition(args.index, endpoint, deployment, len(docs[0]["content_vector"]))
    check(session.put(index + q, json=definition, timeout=60))

    push(session, f"{index}/docs/index{q}", [{"@search.action": "upload", **d} for d in docs])
    stale = indexed_ids(session, f"{index}/docs/search{q}") - {d["id"] for d in docs}
    push(session, f"{index}/docs/index{q}", [{"@search.action": "delete", "id": i} for i in stale])

    print(f"pushed {len(docs)} chunks to {index}, removed {len(stale)} stale")
    print("\nNext: in the Foundry portal, add this index as a knowledge source (README).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
