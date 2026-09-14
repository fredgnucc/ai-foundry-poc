metadata description = 'API Management instance flagged as an AI Gateway.'

param location string
param tags object
param apimName string
param apimSku string
param publisherEmail string
param publisherName string

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: apimSku
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    // Marks the instance as an AI Gateway. Write-only: ARM accepts it but never
    // returns it on GET, so it cannot be asserted after deployment.
    #disable-next-line BCP037
    isAIGateway: true
    apiVersionConstraint: {
      minApiVersion: '2019-12-01'
    }
  }
}

output apimId string = apim.id
output principalId string = apim.identity.principalId
