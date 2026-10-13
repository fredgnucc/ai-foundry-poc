targetScope = 'subscription'

metadata description = 'Azure AI Foundry AI Gateway: Foundry account, project, APIM gateway and the full association, wired end to end.'

@description('Azure region for every resource.')
param location string = 'swedencentral'

@description('Resource group to create.')
param resourceGroupName string = 'rg-ai-gateway'

@description('Prefix for generated resource names.')
param namePrefix string = 'aigw'

@description('Foundry project name.')
param projectName string = 'gateway-poc'

@description('Model to deploy. The deployment is named after the model.')
param modelName string = 'gpt-6-astra'
param modelVersion string = '2026-09-03'
param modelCapacity int = 10

@description('Inference API version pinned into the connection metadata.')
param inferenceApiVersion string = '2024-10-21'

@description('APIM tier. Only v2 tiers support VNet integration.')
@allowed([ 'BasicV2', 'StandardV2', 'PremiumV2' ])
param apimSku string = 'BasicV2'

@description('APIM publisher email (required by the service).')
param publisherEmail string

@description('Tokens per minute per deployment. 0 disables the limit.')
param tokenLimitPerMinute int = 0

@description('Retention for gateway logs and agent traces in Log Analytics.')
param logRetentionInDays int = 30

@description('APIM logs prompts and completions to ApiManagementGatewayLlmLog, not just token counts.')
param logLlmMessages bool = true

@description('Foundry IQ plumbing: embedding model, search service and roles. knowledge.py pushes the repo into an index; the knowledge base itself is built in the portal (README).')
param deployKnowledge bool = true

@description('Free has no managed identity for outbound calls, so it can\'t reach the keyless model.')
@allowed([ 'basic', 'standard' ])
param searchSku string = 'basic'

@description('Only Search moves: Sweden Central creates no new search services (high demand). Pick a region with agentic retrieval and the semantic ranker.')
param searchLocation string = 'switzerlandnorth'

@description('Embedding model that vectorizes the chunks and the questions.')
param embeddingModelName string = 'text-embedding-3-small'
param embeddingModelVersion string = '1'
param embeddingCapacity int = 50

@description('''
Changes every generated resource name. Foundry accounts and API Management soft-delete,
so a redeploy after teardown collides with the reserved name ("FlagMustBeSetForRestore").
Either purge the old resources, or set a new seed here to get fresh names.
''')
param nameSeed string = 'v1'

param tags object = { lab: 'ai-gateway' }

var suffix = uniqueString(subscription().id, resourceGroupName, namePrefix, nameSeed)
var accountName = toLower('${namePrefix}-${suffix}')
var apimName = toLower('${namePrefix}-apim-${suffix}')
var workspaceName = toLower('log-${namePrefix}-${suffix}')
var appInsightsName = toLower('appi-${namePrefix}-${suffix}')
var productName = toLower('${accountName}-${projectName}-ai')
var searchName = toLower('srch-${namePrefix}-${suffix}')

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module foundry 'modules/foundry.bicep' = {
  scope: rg
  name: 'foundry'
  params: {
    location: location
    tags: tags
    accountName: accountName
    projectName: projectName
    modelName: modelName
    modelVersion: modelVersion
    modelCapacity: modelCapacity
  }
}

module gateway 'modules/gateway.bicep' = {
  scope: rg
  name: 'gateway'
  params: {
    location: location
    tags: tags
    apimName: apimName
    apimSku: apimSku
    publisherEmail: publisherEmail
    publisherName: '${accountName} AI Gateway'
  }
}

module association 'modules/association.bicep' = {
  scope: rg
  name: 'association'
  params: {
    accountName: accountName
    apimName: apimName
    projectName: projectName
    productName: productName
    modelName: modelName
    modelVersion: modelVersion
    inferenceApiVersion: inferenceApiVersion
    tokenLimitPerMinute: tokenLimitPerMinute
  }
  dependsOn: [ foundry, gateway ]
}

module observability 'modules/observability.bicep' = {
  scope: rg
  name: 'observability'
  params: {
    location: location
    tags: tags
    workspaceName: workspaceName
    apimName: apimName
    diagnosticSettingName: 'diag-${namePrefix}-apim'
    retentionInDays: logRetentionInDays
    appInsightsName: appInsightsName
    accountName: accountName
    projectName: projectName
    logLlmMessages: logLlmMessages
  }
  // association creates the API that the LLM logging diagnostic attaches to.
  dependsOn: [ foundry, gateway, association ]
}

module knowledge 'modules/knowledge.bicep' = if (deployKnowledge) {
  scope: rg
  name: 'knowledge'
  params: {
    location: location
    tags: tags
    accountName: accountName
    projectName: projectName
    searchName: searchName
    searchSku: searchSku
    searchLocation: searchLocation
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingCapacity: embeddingCapacity
    userPrincipalId: deployer().objectId
  }
  // Last, so its model deployment doesn't overlap the other modules' changes to the account.
  dependsOn: [ foundry, observability ]
}

output accountName string = accountName
output projectName string = projectName
output apimName string = apimName
output connectionName string = accountName
output deploymentName string = modelName
output resourceGroupName string = resourceGroupName
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output gatewayEndpoint string = 'https://${apimName}.azure-api.net/${accountName}'
output workspaceName string = observability.outputs.workspaceName
output appInsightsName string = observability.outputs.appInsightsName
output searchName string = knowledge.?outputs.searchName ?? ''
