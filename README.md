# Azure AI Foundry — AI Gateway

Deploys an AI Foundry account, a project, a model deployment, and an API Management
instance acting as an **AI Gateway**, fully wired so agents call the model through it.
It also deploys what a [Foundry IQ](#foundry-iq-ask-the-agent-about-this-repo) knowledge
base needs, so the agent can answer questions about this repo.

Everything is Bicep except what ARM can't hold: `agent.py` creates the agent and
`knowledge.py` fills the search index.

## Prerequisites

- Azure CLI, logged in: `az login`
- Python 3.9+
- Contributor + User Access Administrator (or Owner) on the subscription

## Deploy

```powershell
# 1. set your email (required by API Management)
#    edit params/main.json -> publisherEmail

# 2. deploy the infrastructure  (~5 minutes)
az deployment sub create `
  --name ai-gateway `
  --location swedencentral `
  --template-file main.bicep `
  --parameters params/main.json

# 3. create the agent
pip install -r requirements.txt
python agent.py

# 4. fill the search index for Foundry IQ (see below)
python knowledge.py
```

```powershell
python agent.py --name my-agent          # through the gateway
python agent.py --name my-agent --direct # bypass the gateway
```

## Foundry IQ: ask the agent about this repo

A Foundry IQ knowledge base lets the agent answer questions about this lab, such as
*How do I enable LLM logs in my APIM?* The work is split three ways:

- **Bicep** (`modules/knowledge.bicep`): an embedding model, an Azure AI Search service,
  and the roles between them.
- **`knowledge.py`**: chunks the files tracked by git, embeds them, and pushes them into
  the search index `repo-docs`. Re-run it after each commit: it updates the index in place
  and removes the chunks of deleted files.
- **Foundry portal**: the knowledge base itself, and its link to the agent.

After `python knowledge.py`, open [Foundry (new)](https://ai.azure.com), project
`gateway-poc`, **Build**:

1. **Knowledge**: connect the search service (output `searchName`) with **Microsoft
   Entra ID** authentication. The service accepts no keys.
2. Create a knowledge base with one knowledge source of type **Azure AI Search index**,
   index `repo-docs`. Set retrieval reasoning effort to **minimal** and output to
   **extractive**: `gpt-6-astra` isn't one of the models a knowledge base can use for
   query planning.
3. **Agents** → `gateway-agent`: add the knowledge base, with instructions such as
   *Use the knowledge base tool to answer user questions. If the knowledge base doesn't
   contain the answer, respond with "I don't know". When you use information from the
   knowledge base, include citations to the retrieved sources.*
4. Ask in the playground: *How do I enable LLM logs in my APIM?*

Why it looks like this:

- **An index, not a blob container.** Foundry IQ can't read GitHub, and a tenant policy
  disables public network access on every storage account, so Search can't index a
  container without private networking end to end. `knowledge.py` does the indexing.
- **Search in Switzerland North** (`searchLocation`). Sweden Central creates no new search
  services (high demand). Only Search moves: it reaches the model, and the agent reaches
  it, over public endpoints.
- **Basic tier.** The account accepts no keys, so Search calls the embedding model with
  its managed identity, which the Free tier doesn't have. The semantic ranker runs on its
  free plan, about 1,000 queries a month.
- `python agent.py` creates an agent version with no tools: add the knowledge base again
  afterwards.
- A `403` from `knowledge.py` right after a deployment is usually role propagation; retry
  after a few minutes.
- `deployKnowledge=false` skips all of it. Search bills by the hour, even when idle.

## Clean up

```powershell
az group delete --name rg-ai-gateway --yes
```

Foundry accounts and API Management **soft-delete**: the names stay reserved (~48 h) and a
redeploy fails with `FlagMustBeSetForRestore`. Either purge them, or redeploy with a new
`nameSeed`.

```powershell
# purge (frees the names immediately)
$sub = az account show --query id -o tsv
az rest --method get --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.CognitiveServices/deletedAccounts?api-version=2024-10-01" `
  --query "value[].id" -o tsv | ForEach-Object { az rest --method delete --url "https://management.azure.com$_`?api-version=2024-10-01" }

az rest --method get --url "https://management.azure.com/subscriptions/$sub/providers/Microsoft.ApiManagement/deletedservices?api-version=2024-05-01" `
  --query "value[].id" -o tsv | ForEach-Object { az rest --method delete --url "https://management.azure.com$_`?api-version=2024-05-01" }
```

```powershell
# or skip the wait entirely - any new seed generates fresh names
az deployment sub create ... --parameters nameSeed=v2
```

## How it works

Two authentication hops, deliberately separate:

```
agent ──► ModelGateway ──► APIM ──► model
              api-key          managed identity
```

- The **connection** (`accounts/connections`, account-scoped) makes the gateway
  addressable and supplies the API key. Projects inherit it.
- `definition.model` on the agent is `"<connection>/<deployment>"`. That prefix is what
  sends traffic through the gateway; a bare deployment name bypasses it.
- The APIM **backend URL must end in `/openai`**. The ModelGateway sends
  `/<account>/deployments/<deployment>/chat/completions`; APIM strips its path prefix
  and forwards `/deployments/...`, which the account serves only under `/openai/`.
- The API has no `serviceUrl` and no `backendId` — routing exists **only** in the API
  policy, via `set-backend-service`. Without that policy every call returns `500`.
- Token limits are split across two scopes: the **product** policy holds the values, the
  **API** policy holds the enforcement engine. Neither works alone.
- `Microsoft.Resources/links` are presentation only — they make the gateway appear in the
  portal's AI Gateway list but play no part in routing.
- Per-request evidence needs the **diagnostic setting** in `modules/observability.bicep`.
  Without it the APIM `Requests` metric still counts traffic, but Logs and the Analytics
  dashboard stay empty, which looks like the gateway is bypassed. Agent calls land in
  `ApiManagementGatewayLogs` with `ApimSubscriptionId` = `<account>-<project>-ai` (the
  connection's key). A new workspace can take up to 2 hours to receive its first rows.
- APIM's own record of each model call — model, tokens, prompt and completion — lands in
  `ApiManagementGatewayLlmLog`. It takes two switches, both in `modules/observability.bicep`:
  the diagnostic setting exports `GatewayLlmLogs`, and an API-level `azuremonitor`
  diagnostic turns on LLM logging (`largeLanguageModel`; portal: API → Settings → Azure
  Monitor → **Log LLM messages**). Export alone leaves the table empty. Rows arrive 2–5
  minutes after the call, and large messages are split into chunks that query 4 in
  `docs/queries.kql` rejoins. The text is kept in clear for the workspace retention;
  `logLlmMessages=false` keeps model and tokens only.
- Agent **traces** need an Application Insights connection on the project, also in
  `modules/observability.bicep`. With it, Foundry traces prompt agents server-side with no
  code change and fills the Traces, Insights and Monitor tabs. `AppDependencies` gets the
  `invoke_agent` and `chat <connection>/<deployment>` spans (with token counts) and
  `AppGenAIContent` gets the prompts and replies. Both land in the gateway's workspace, so
  `docs/queries.kql` can join a trace to its gateway call. The project identity gets Log
  Analytics Reader and Privileged Monitoring Data Reader on the component to read traces back.
- **Foundry IQ** uses three identities, all wired in `modules/knowledge.bicep`. The search
  service's identity turns each question into a vector with the embedding model
  (Cognitive Services User on the account). The project's identity queries the knowledge
  base for the agent (Search Index Data Reader). The deployer embeds and pushes the chunks
  (Cognitive Services OpenAI User, Search Index Data Contributor): Owner and Contributor
  define indexes and knowledge bases, but can't read or write documents. Embedding calls
  go straight to the account; only the agent's chat model goes through APIM.

## Layout

```
main.bicep               subscription-scope entry point
modules/foundry.bicep    account, model deployment, project
modules/gateway.bicep    API Management (isAIGateway)
modules/association.bicep RBAC, backend, API, operations, policy, product, links, connection
modules/observability.bicep Log Analytics workspace, APIM diagnostic setting + LLM logging, App Insights + tracing connections
modules/knowledge.bicep  embedding model, AI Search, roles for Foundry IQ
modules/policy.xml       APIM API policy
params/main.json         parameters
agent.py                 creates the agent (data plane, not ARM)
knowledge.py             pushes the repo into the search index (data plane, not ARM)
docs/                    how the portal builds this, reverse-engineered from ARM
docs/queries.kql         KQL: gateway traffic, prompts and replies (Foundry and APIM), trace-to-gateway join
```

## Background

`docs/portal-arm-calls.md` records what the Azure AI Foundry portal actually writes to
ARM for an AI Gateway, captured from a live subscription. It documents the two portal
defects this template avoids, how gateway discovery really works, and the agent data-plane
schema in `docs/agent-schema-sample.json`.
