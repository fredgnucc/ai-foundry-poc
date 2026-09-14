metadata description = 'Foundry account (AIServices), model deployment and project.'

param location string
param tags object
param accountName string
param projectName string
param modelName string
param modelVersion string
param modelCapacity int

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Required before any project can be created under the account.
    allowProjectManagement: true
    customSubDomainName: accountName
    // Public on purpose: a Foundry-managed agent reaches models through the
    // platform ModelGateway, which calls from a public IP. A network-private
    // gateway is unreachable for managed agents.
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: account
  name: modelName
  sku: {
    name: 'GlobalStandard'
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectName
  }
  dependsOn: [ deployment ]
}

output accountId string = account.id
output projectId string = project.id
