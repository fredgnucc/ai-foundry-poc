metadata description = '''
Telemetry for the gateway and the agents behind it, in one Log Analytics workspace.

Gateway logs come from the APIM diagnostic setting. Without it, the APIM Requests metric
still counts traffic, but Logs and the Azure Monitor-based Analytics dashboard (the only
analytics in v2 tiers) stay empty, which looks exactly like the agent bypassing the gateway.

LLM logs need two switches: the diagnostic setting exports GatewayLlmLogs, and an API-level
azuremonitor diagnostic turns on LLM logging (largeLanguageModel). Exporting alone leaves
ApiManagementGatewayLlmLog empty.

Agent traces come from a workspace-based Application Insights connected to the account and
the project. Foundry turns on server-side tracing for prompt agents as soon as that
connection exists (no code change) and fills the Traces, Insights and Monitor tabs.
'''

param location string
param tags object
param workspaceName string
param apimName string
param diagnosticSettingName string
param appInsightsName string
param accountName string
param projectName string

@description('Record prompts and completions in ApiManagementGatewayLlmLog. False keeps only the model and token counts.')
param logLlmMessages bool = true

@description('Kept short deliberately - this is POC evidence, not retained telemetry.')
param retentionInDays int = 30

var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'
// Required on top of Log Analytics Reader to read GenAI content (prompts, completions).
var privilegedMonitoringDataReaderRoleId = 'dbc9c667-e97f-4491-aee6-90b9cf960190'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// Diagnostic settings are extension resources, so the scope is the APIM instance.
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  scope: apim
  properties: {
    workspaceId: workspace.id
    // 'Dedicated' gives the documented ApiManagementGatewayLogs schema. The default
    // writes to the legacy AzureDiagnostics table and leaves ApiManagementGatewayLogs empty.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
    ]
  }
}

// The API is named after the account (modules/association.bicep).
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  parent: apim
  name: accountName
}

// Declared rather than referenced as existing, so a template-only deployment doesn't depend on
// the portal having set up Azure Monitor logging. Properties match the live logger.
resource azureMonitorLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    isBuffered: true
  }
}

// API-level settings replace the service-wide ones for this API, so the service defaults are
// restated. Hiding query parameters matters: the API accepts the key as ?subscription-key=.
var hideQueryParams = { dataMasking: { queryParams: [ { mode: 'Hide', value: '*' } ] } }
// The maximum. Agents resend the whole conversation with the newest message last, so a smaller
// cap truncates exactly what was just typed. Large messages arrive in chunks (SequenceNumber).
var llmMessages = { messages: 'all', maxSizeInBytes: 262144 }

resource llmLogging 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: api
  name: 'azuremonitor'
  properties: {
    loggerId: azureMonitorLogger.id
    logClientIp: true
    sampling: { samplingType: 'fixed', percentage: 100 }
    frontend: { request: hideQueryParams }
    backend: { request: hideQueryParams }
    largeLanguageModel: logLlmMessages ? {
      logs: 'enabled'
      requests: llmMessages
      responses: llmMessages
    } : {
      logs: 'enabled'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
  }
}

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: account
  name: projectName
}

// Account and project connections, as in the official foundry-samples template. The key is
// the connection string, read at deploy time so it never lands in source control.
resource accountTracing 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  parent: account
  name: '${accountName}-appinsights'
  properties: {
    category: 'AppInsights'
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: { key: appInsights.properties.ConnectionString }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsights.id
    }
  }
}

resource projectTracing 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: appInsightsName
  properties: {
    category: 'AppInsights'
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: { key: appInsights.properties.ConnectionString }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsights.id
    }
  }
}

// Lets the project identity read the traces back, which evaluations and Insights need.
resource projectCanReadTraces 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in [ logAnalyticsReaderRoleId, privilegedMonitoringDataReaderRoleId ]: {
  name: guid(project.id, roleId, appInsights.id)
  scope: appInsights
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    principalType: 'ServicePrincipal'
  }
}]

output workspaceId string = workspace.id
output workspaceName string = workspace.name
output appInsightsName string = appInsights.name
