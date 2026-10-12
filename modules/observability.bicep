metadata description = '''
Gateway telemetry: a Log Analytics workspace and the APIM diagnostic setting that feeds it.

Without the diagnostic setting, the APIM Requests metric still counts traffic, but Logs
and the Azure Monitor-based Analytics dashboard (the only analytics in v2 tiers) stay
empty, which looks exactly like the agent bypassing the gateway.

GatewayLlmLogs is enabled alongside GatewayLogs because it carries the model and token
detail that the token-limit policy acts on.
'''

param location string
param tags object
param workspaceName string
param apimName string
param diagnosticSettingName string

@description('Kept short deliberately - this is POC evidence, not retained telemetry.')
param retentionInDays int = 30

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

output workspaceId string = workspace.id
output workspaceName string = workspace.name
