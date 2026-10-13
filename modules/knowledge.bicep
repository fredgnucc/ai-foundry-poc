metadata description = '''
Foundry IQ plumbing: what a knowledge base needs before it is built in the Foundry portal.

Foundry IQ can't read GitHub, and a tenant policy forces every storage account to disable
public network access, so a blob knowledge source would need private networking end to end.
Instead, knowledge.py chunks and embeds the repo files and pushes them into an index on this
search service, and the portal exposes that index as a knowledge source.

The Foundry account accepts no keys, and a Free search service has no managed identity for
outbound calls, so Basic is the lowest tier that works.

Three identities, three jobs:
- the search identity calls the embedding model to vectorize questions at query time
- the project identity queries the knowledge base when the agent calls it as a tool
- the deployer embeds and pushes the chunks, and tests the knowledge base
'''

param location string
param tags object
param accountName string
param projectName string
param searchName string

@description('Search can sit in another region than the rest: the agent and the search identity reach it, and it reaches the model, over public endpoints.')
param searchLocation string = location

@description('Free has no managed identity for outbound calls, so it can\'t reach the keyless model.')
@allowed([ 'basic', 'standard' ])
param searchSku string = 'basic'

@description('Embedding model that vectorizes the chunks and the questions.')
param embeddingModelName string = 'text-embedding-3-small'
param embeddingModelVersion string = '1'
param embeddingCapacity int = 50

@description('Object ID that gets the data-plane roles to embed and push the chunks and to test the knowledge base. Empty skips them.')
param userPrincipalId string = ''

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var cognitiveServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var searchIndexDataReaderRoleId = '1407120a-92aa-4202-b7e9-c0e197c71c8f'
var searchIndexDataContributorRoleId = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: projectName
}

// Search and knowledge.py call this deployment directly, not through APIM.
// Only the agent's chat model goes through the gateway.
resource embedding 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: embeddingModelName
  sku: {
    name: 'GlobalStandard'
    capacity: embeddingCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
  }
}

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchName
  location: searchLocation
  tags: tags
  sku: { name: searchSku }
  identity: { type: 'SystemAssigned' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    // The agent reaches the knowledge base from the Foundry platform, over the public endpoint.
    publicNetworkAccess: 'enabled'
    disableLocalAuth: true
    // Agentic retrieval reranks with the semantic ranker. The free plan has a monthly allowance.
    semanticSearch: 'free'
  }
}

// Cognitive Services User, as Foundry IQ documents for the search identity, also covers a
// query-planning model if the knowledge base's reasoning effort is raised above minimal.
resource searchCallsModels 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, cognitiveServicesUserRoleId, account.id)
  scope: account
  properties: {
    principalId: search.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource projectQueriesKnowledge 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(project.id, searchIndexDataReaderRoleId, search.id)
  scope: search
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataReaderRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Owner and Contributor define indexes and knowledge bases, but read and write no data.
resource userEmbedsChunks 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  name: guid(userPrincipalId, cognitiveServicesOpenAIUserRoleId, account.id)
  scope: account
  properties: {
    principalId: userPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRoleId)
  }
}

resource userPushesChunks 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(userPrincipalId)) {
  name: guid(userPrincipalId, searchIndexDataContributorRoleId, search.id)
  scope: search
  properties: {
    principalId: userPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributorRoleId)
  }
}

output searchName string = search.name
output embeddingEndpoint string = account.properties.endpoints['OpenAI Language Model Instance API']
output embeddingDeploymentName string = embedding.name
