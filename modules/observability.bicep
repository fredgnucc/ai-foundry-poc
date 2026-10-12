metadata description = '''
Telemetry for the gateway and the agents behind it, in one Log Analytics workspace.

Gateway logs come from the APIM diagnostic setting. Without it, the APIM Requests metric
still counts traffic, but Logs and the Azure Monitor-based Analytics dashboard (the only
analytics in v2 tiers) stay empty, which looks exactly like the agent bypassing the gateway.

GatewayLlmLogs is exported too, but ApiManagementGatewayLlmLog (model, tokens) only gets
rows once LLM logging (largeLanguageModel) is enabled on APIM's azuremonitor diagnostic,
which this template does not do.

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
