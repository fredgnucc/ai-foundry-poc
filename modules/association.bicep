metadata description = 'Wires the gateway to the Foundry account: RBAC, backend, API, operations, policy, product, links and the admin-connected model.'

param accountName string
param apimName string
param projectName string
param productName string
param modelName string
param modelVersion string
param inferenceApiVersion string
param tokenLimitPerMinute int

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: projectName
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// Cognitive Services OpenAI User - least-privilege role covering
// deployments/chat/completions and responses/*.
var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// Hop 2 of 2: APIM -> model, authenticated with the gateway's managed identity.
// (Hop 1 is caller -> APIM, authenticated with the subscription key below.)
resource gatewayCanCallModel 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, apim.id, openAiUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// The /openai segment is mandatory. The ModelGateway sends
//   /<account>/deployments/<deployment>/chat/completions
// APIM strips its API path prefix and forwards /deployments/..., which the Foundry
// account only serves under /openai/. Without it every model call returns 404.
resource backend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: accountName
  properties: {
    url: 'https://${accountName}.services.ai.azure.com/openai'
    protocol: 'http'
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: 'https://ai.azure.com/'
      }
    }
    tls: {
      validateCertificateChain: false
      validateCertificateName: false
    }
  }
}

// serviceUrl and backendId are deliberately unset: routing lives exclusively in the
// API policy below, via set-backend-service.
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: accountName
  properties: {
    displayName: accountName
    path: accountName
    protocols: [ 'https' ]
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
  }
}

var verbs = [ 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS', 'TRACE' ]

// Catch-all surface: any path under the API prefix is forwarded verbatim.
resource operations 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = [for verb in verbs: {
  parent: api
  name: '${toLower(verb)}-default'
  properties: {
    displayName: '${toLower(verb)}-default'
    method: verb
    urlTemplate: '/*'
  }
}]

// Without this policy APIM has no destination at all and returns HTTP 500.
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('policy.xml'), '__BACKEND__', accountName)
  }
  dependsOn: [ operations, backend ]
}

resource product 'Microsoft.ApiManagement/service/products@2024-06-01-preview' = {
  parent: apim
  name: productName
  properties: {
    displayName: productName
    state: 'published'
    subscriptionRequired: true
    approvalRequired: false
  }
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2024-06-01-preview' = {
  parent: product
  name: api.name
}

resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: productName
  properties: {
    scope: product.id
    displayName: productName
    state: 'active'
  }
}

// Token governance is split across two scopes: the product policy holds the limit
// VALUES, the API policy holds the enforcement ENGINE. Neither works alone.
resource productPolicy 'Microsoft.ApiManagement/service/products/policies@2024-06-01-preview' = if (tokenLimitPerMinute > 0) {
  parent: product
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><set-variable name="tokenlimit-${modelName}" value="${tokenLimitPerMinute}" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// Admin-connected model. Account-scoped: projects inherit it.
// models[].name is the deployment name and becomes a URL path segment, so it must
// match a real deployment. deploymentInPath and inferenceAPIVersion decide the URL
// shape the ModelGateway builds.
resource connection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: accountName
  properties: {
    authType: 'ApiKey'
    category: 'ApiManagement'
    target: 'https://${apimName}.azure-api.net/${accountName}'
    isSharedToAll: true
    credentials: {
      key: apimSubscription.listSecrets().primaryKey
    }
    metadata: {
      deploymentInPath: 'true'
      inferenceAPIVersion: inferenceApiVersion
      authConfig: '{"type":"api_key","name":"api-key","format":"{api_key}"}'
      customHeaders: '{}'
      models: string([
        {
          name: modelName
          properties: {
            model: {
              name: modelName
              version: modelVersion
              format: 'OpenAI'
            }
          }
        }
      ])
    }
  }
  dependsOn: [ apiPolicy ]
}

// Links are presentation only, but they are what makes the gateway appear in the
// Foundry portal's AI Gateway list. Routing works without them.
resource linkAccountToGateway 'Microsoft.Resources/links@2016-09-01' = {
  scope: account
  name: 'aigw-${apimName}'
  properties: {
    targetId: apim.id
  }
}

resource linkGatewayToAccount 'Microsoft.Resources/links@2016-09-01' = {
  scope: apim
  name: 'aigw-${accountName}'
  properties: {
    targetId: account.id
  }
}

resource linkProjectToProduct 'Microsoft.Resources/links@2016-09-01' = {
  scope: project
  name: 'aigw-${productName}'
  properties: {
    targetId: product.id
  }
}

output backendUrl string = backend.properties.url
output productId string = product.id
