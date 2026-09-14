# Portal ARM calls — Azure AI Foundry "AI Gateway"

What the Azure AI Foundry portal actually writes to ARM when you create an AI Gateway
and associate it with a Foundry account and project.

Captured on 2026-09-13/14 from a live subscription using three independent sources:

| Source | What it gives | Command |
|---|---|---|
| Activity Log | ordered list of ARM writes, with timestamps | `az monitor activity-log list -g <rg> --start-time <iso>` |
| Deployment export | the literal template the portal submitted | `az deployment group export -g <rg> -n <name>` |
| ARM GET on each artifact | the resulting request bodies | `Invoke-RestMethod` with a bearer token |

> The Activity Log retains 90 days and disappears when resources are deleted.
> Capture before teardown.

---

## Phase A — Gateway creation

The portal submits a **resource-group deployment** named `<apimName>-<epoch>` containing a
single resource. Everything else in this document is written afterwards by **direct ARM
PUT calls**, not by a template.

```jsonc
{
  "type": "Microsoft.ApiManagement/service",
  "name": "heh",
  "location": "swedencentral",
  "sku": { "name": "BasicV2", "capacity": 1 },
  "identity": { "type": "SystemAssigned" },
  "properties": {
    "publisherEmail": "<signed-in user UPN>",
    "publisherName": "<accountName> AI Gateway",
    "isAIGateway": true,
    "apiVersionConstraint": { "minApiVersion": "2019-12-01" }
  }
}
```

Notable:

- **`isAIGateway: true`** is a first-class APIM property and is what makes the instance
  appear as an AI Gateway in Foundry. It is reproducible in Bicep.
- **It is write-only.** ARM accepts it on PUT/PATCH but never returns it on GET — at any
  api-version tried (`2022-08-01`, `2023-09-01-preview`, `2024-05-01`,
  `2024-06-01-preview`). Confirmed by reading back a *portal-created, working* gateway,
  which also omits it. Do not assert it in a validator; confirm via portal discovery
  instead. The portal writes it at **`2024-06-01-preview`** — use that api-version, since
  older ones may silently drop an unrecognised property.
- The identity is **SystemAssigned** and is later used as the backend credential.
- `publisherName` follows the pattern `<accountName> AI Gateway`.
- Tier is whatever you pick in the dialog. **Basic v2 has no VNet integration**, so it
  cannot reach a network-isolated Foundry account
  ([v2 tiers](https://learn.microsoft.com/en-us/azure/api-management/v2-service-tiers-overview#networking-options)).

---

## Phase B — Association ("Add AI Gateway")

Five ordered groups of direct PUTs. Observed order matters: the backend exists before the
API references it, and the policy is written after the operations.

```
1. backends/<accountName>
2. apis/<accountName>
3. apis/<accountName>/operations/{get,post,put,patch,delete,head,options,trace}-default
4. apis/<accountName>/policies/policy
5. Microsoft.Resources/links   (x2 or x3)
```

### 1. Backend

```jsonc
{
  "properties": {
    "url": "https://<accountName>.services.ai.azure.com/",   // DEFECT: see below
    "protocol": "http",
    "credentials": {
      "managedIdentity": { "resource": "https://ai.azure.com/", "clientId": null }
    },
    "tls": { "validateCertificateChain": false, "validateCertificateName": false }
  }
}
```

Auth lives on the **backend**, not in the policy. This differs from the common
hand-written pattern that uses `<authentication-managed-identity>` in the API policy.

### 2. API

```jsonc
{
  "properties": {
    "displayName": "<accountName>",
    "path": "<accountName>",
    "protocols": ["https"],
    "serviceUrl": null,          // routing is NOT here
    "backendId": null,           // and NOT here
    "subscriptionRequired": true,
    "subscriptionKeyParameterNames": { "header": "api-key", "query": "subscription-key" }
  }
}
```

Both `serviceUrl` and `backendId` are `null`. **Routing exists only inside the API
policy.** If the policy is missing, APIM has no destination and returns HTTP 500.

### 3. Operations — 8 wildcard verbs

| name | method | urlTemplate |
|---|---|---|
| `get-default` | GET | `/*` |
| `post-default` | POST | `/*` |
| `put-default` | PUT | `/*` |
| `patch-default` | PATCH | `/*` |
| `delete-default` | DELETE | `/*` |
| `head-default` | HEAD | `/*` |
| `options-default` | OPTIONS | `/*` |
| `trace-default` | TRACE | `/*` |

A catch-all surface: any path under the API prefix is accepted and forwarded verbatim.
This is why a wrong URL shape fails at the *backend* rather than at APIM.

### 4. API policy

Two responsibilities in one document — routing and token governance:

```xml
<policies>
  <inbound>
    <base />
    <set-backend-service id="apim-generated-policy" backend-id="<accountName>" />
    <choose>
      <when condition="@(context.Variables.ContainsKey("tokenlimit-"+(string)context.Request.Foundry.Deployment)
                     || context.Variables.ContainsKey("tokenquota-"+(string)context.Request.Foundry.Deployment))">
        <!-- resolves tokenlimit-<deployment> / tokenquota-<deployment> into llm-token-limit -->
      </when>
      <otherwise />
    </choose>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
```

- `context.Request.Foundry.Deployment` is a **native context property**, not a variable.
- The token-limit branch is dead code until a limit is configured — it reads variables set
  by the *product* policy.

### 5. Product, subscription and product policy

```jsonc
// products/<accountName>-<projectName>-ai-<random8>
{ "displayName": "<same>", "state": "published",
  "subscriptionRequired": true, "approvalRequired": false }
```

Setting a token limit in the portal writes a **product** policy:

```xml
<policies>
  <inbound>
    <base />
    <set-variable name="tokenlimit-<deploymentName>" value="50" />
  </inbound>
  ...
</policies>
```

So governance is split across two scopes: the **product** holds the values, the **API**
holds the engine. Neither works without the other.

### 6. Links

`Microsoft.Resources/links` are **bidirectional**, and a project association adds a third:

| source | target |
|---|---|
| `CognitiveServices/accounts/<account>` | `ApiManagement/service/<apim>` |
| `ApiManagement/service/<apim>` | `CognitiveServices/accounts/<account>` |
| `CognitiveServices/accounts/<account>/projects/<project>` | `ApiManagement/service/<apim>/products/<product>` |

Links are **presentation only** — they drive portal display, not routing. Their absence
does not break inference.

### What actually drives portal discovery (measured)

The Foundry **AI Gateway** list is built from the **account→service link**, not from
`isAIGateway`:

| State of the APIM instance | Listed in Foundry? |
|---|---|
| `isAIGateway: true`, no links, no API/backend | **No** |
| `isAIGateway: true` + account→service link only | **Yes** — `Resource 1, Projects 1` |

Isolated by creating a gateway with the flag alone (not listed), then adding only the two
account↔service links and refreshing (listed immediately).

Column meanings, also measured:

- **Resource** — number of linked Foundry accounts.
- **Projects** — number of projects **on the linked account**. It is *not* a count of
  project→product links: the instance above showed `Projects 1` with no product and no
  project link, because the account happened to have one project.

Practical consequence: "Add existing gateway" in the portal is largely a link-writing
operation for *display*. The artifacts that make inference actually work — backend, API,
operations and policy — are separate, which is exactly why a gateway can look correctly
associated in the UI and still return 500 or 404.

Two further details: link **names are random 16-character lowercase strings**, and ARM
**normalises `targetId` with a trailing slash** on write.

---

## Phase C — Admin-connected model

An **account-level** connection (projects inherit it; they do not own a copy). Verified:
the account lists the `ApiManagement` connection, and the project's own connection
collection is **empty**. This is why an admin-connected model appears in every project
under the resource without per-project configuration, and why the UI surfaces it under
the **Resource** section rather than the project.

The portal names the connection after the **account**, not the gateway
(`example-account`, matching the API name).

```jsonc
// accounts/<account>/connections/<name>   api-version=2025-04-01-preview
{
  "properties": {
    "authType": "ApiKey",
    "category": "ApiManagement",
    "group": "AzureAI",
    "target": "https://<apim>.azure-api.net/<accountName>",
    "isSharedToAll": true,
    "metadata": {
      "deploymentInPath": "false",
      "inferenceAPIVersion": "",
      "authConfig": "{\"type\":\"api_key\",\"name\":\"api-key\",\"format\":\"{api_key}\"}",
      "customHeaders": "{}",
      "models": "[{\"name\":\"gpt-6-astra\",\"properties\":{\"model\":{\"name\":\"<display name>\",\"version\":\"\",\"format\":\"OpenAI\"}}}]"
    }
  }
}
```

Portal dialog field mapping:

| Dialog field | Lands in | Meaning |
|---|---|---|
| **Name** | `models[].name` | the **deployment name**, used as the URL path segment |
| **Display name** | `models[].properties.model.name` | label shown in the model picker |

`Name` must match a real deployment on the account behind the gateway, otherwise every
call returns HTTP 404.

### Updating a connection

`PUT` fails with `Credentials Property can't be empty for auth type ApiKey` because ARM
never returns the key. Use `PATCH`, and include the `authType` discriminator:

```jsonc
PATCH .../connections/<name>?api-version=2025-04-01-preview
{ "properties": { "authType": "ApiKey", "metadata": { "deploymentInPath": "true" } } }
```

---

## Phase D — Agents are NOT ARM

Prompt / managed agents are **data-plane** objects under the project endpoint:

```
https://<account>.services.ai.azure.com/api/projects/<project>/...
```

They never appear in the Activity Log, in `az resource list`, or in any ARM snapshot.

### Captured agent schema

Retrieved with `GET /api/projects/<project>/agents/<name>?api-version=v1` against a
portal-created agent:

```jsonc
{
  "object": "agent", "id": "example-agent", "state": "enabled",
  "versions": {
    "latest": {
      "version": "4",
      "definition": {
        "kind": "prompt",
        "model": "example-account/gpt-6-astra",   // <connection>/<deployment>
        "instructions": "",
        "tools": []
      },
      "instance_identity":    { "principal_id": "...", "client_id": "..." },
      "blueprint_reference":  { "type": "ManagedAgentIdentityBlueprint", "blueprint_id": "..." }
    }
  },
  "agent_endpoint": {
    "protocols": ["responses"],
    "authorization_schemes": [{ "type": "Entra" }],
    "version_selector": { "version_selection_rules": [
      { "type": "FixedRatio", "agent_version": "@latest", "traffic_percentage": 100 } ] }
  }
}
```

Key points:

- **Agents are versioned.** `definition` is nested under `versions.latest`, not at the top
  level, and each save increments a version. The endpoint routes traffic by rule
  (`FixedRatio`, `@latest`, 100%), so blue/green between agent versions is built in.
- **`definition.model` is `"<connectionName>/<deploymentName>"`.** The connection prefix is
  what selects the AI Gateway path; without it the deployment is called directly. This is
  the single field that decides whether traffic traverses APIM.
- **Each agent gets its own managed identity**, plus a shared "blueprint" identity. Neither
  is an ARM resource, so neither is visible to `az role assignment list` by resource scope.
- Listing returns an **OpenAI-style envelope** (`data` / `has_more` / `object`), not ARM's
  `value`.

The only way to capture *creation* calls specifically is browser DevTools → Network,
filtered on the account endpoint. The resulting object, however, is fully readable via the
GET above.

---

## Defects observed in portal output

Both produce opaque errors that name no layer.

| # | Defect | Symptom | Fix |
|---|---|---|---|
| 1 | API policy not written at all | **HTTP 500** on every model call | PUT a policy containing `set-backend-service` |
| 2 | Backend URL missing `/openai` | **HTTP 404** `{"error":{"code":"404","message":"Resource not found"}}` | append `/openai` to the backend URL |

Defect 2 in detail: ModelGateway sends

```
/<accountName>/deployments/<deployment>/chat/completions?api-version=<ver>
```

APIM strips the API path prefix and forwards `/deployments/...` to the backend. The Foundry
account serves that route under `/openai/`, so it 404s at the root. Documented behaviour
matches the vague troubleshooting entry *"500 errors on model calls after gateway setup"*.

Defect 1 was observed on a freshly created gateway; on a pre-existing APIM whose API was
already named after the account, the policy **was** written. Behaviour differs between
clean and pre-existing instances.

---

## Diagnostic method

Guessing at URL shapes stalled. Two read-only measurements resolved it:

1. **Locate the failing layer** — split the APIM `Requests` metric by dimension:

   ```powershell
   az monitor metrics list --resource <apimId> --metric Requests \
     --filter "BackendResponseCode eq '*'" --aggregation Total
   ```

   `BackendResponseCode=404` with `LastErrorReason=None` proves APIM matched and forwarded,
   and that the upstream rejected it.

2. **Capture the literal URL** — enable an APIM App Insights logger + diagnostic at 100%
   sampling, then:

   ```kusto
   requests | where timestamp > ago(30m) | project timestamp, resultCode, url
   ```

---

## Mapping to Bicep

| Portal artifact | Bicep type |
|---|---|
| Gateway | `Microsoft.ApiManagement/service` (`properties.isAIGateway: true`) |
| Backend | `Microsoft.ApiManagement/service/backends` |
| API | `Microsoft.ApiManagement/service/apis` |
| Operations | `Microsoft.ApiManagement/service/apis/operations` (8) |
| API policy | `Microsoft.ApiManagement/service/apis/policies` |
| Product | `Microsoft.ApiManagement/service/products` |
| Product policy | `Microsoft.ApiManagement/service/products/policies` |
| Subscription | `Microsoft.ApiManagement/service/subscriptions` |
| Links | `Microsoft.Resources/links` |
| Admin-connected model | `Microsoft.CognitiveServices/accounts/connections` |
| **Agent** | **not ARM** — data-plane REST/SDK |

