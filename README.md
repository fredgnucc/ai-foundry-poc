# Azure AI Foundry — AI Gateway

Deploys an AI Foundry account, a project, a model deployment, and an API Management
instance acting as an **AI Gateway**, fully wired so agents call the model through it.

Everything except the agent is Bicep. Agents are not ARM resources, so one Python
script creates them.

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
```

Then open <https://ai.azure.com>, select the project, and chat with the agent.

## Verify the gateway routes traffic

```powershell
$out  = az deployment sub show -n ai-gateway --query properties.outputs -o json | ConvertFrom-Json
$key  = az apim subscription show -g $out.resourceGroupName.value -n $out.apimName.value `
          --sid "$($out.accountName.value)-$($out.projectName.value)-ai" --query primaryKey -o tsv

Invoke-RestMethod -Method POST `
  -Uri "$($out.gatewayEndpoint.value)/deployments/$($out.deploymentName.value)/chat/completions?api-version=2024-10-21" `
  -Headers @{ 'api-key' = $key; 'Content-Type' = 'application/json' } `
  -Body ([Text.Encoding]::UTF8.GetBytes((@{
      messages = @(@{ role = 'user'; content = 'Reply with exactly: gateway routed ok' })
      max_completion_tokens = 20
  } | ConvertTo-Json -Depth 5)))
```

A `200` with `gateway routed ok` means the whole chain works.

## Options

| Parameter | Default | Notes |
|---|---|---|
| `apimSku` | `BasicV2` | Only v2 tiers support VNet integration |
| `modelCapacity` | `10` | Thousands of tokens per minute |
| `tokenLimitPerMinute` | `0` | `0` disables the token limit |

```powershell
python agent.py --name my-agent          # through the gateway
python agent.py --name my-agent --direct # bypass the gateway
```

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

## Layout

```
main.bicep               subscription-scope entry point
modules/foundry.bicep    account, model deployment, project
modules/gateway.bicep    API Management (isAIGateway)
modules/association.bicep RBAC, backend, API, operations, policy, product, links, connection
modules/policy.xml       APIM API policy
params/main.json         parameters
agent.py                 creates the agent (data plane, not ARM)
docs/                    how the portal builds this, reverse-engineered from ARM
```

## Background

`docs/portal-arm-calls.md` records what the Azure AI Foundry portal actually writes to
ARM for an AI Gateway, captured from a live subscription. It documents the two portal
defects this template avoids, how gateway discovery really works, and the agent data-plane
schema in `docs/agent-schema-sample.json`.
