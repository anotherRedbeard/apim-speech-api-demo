// =============================================================================
// Azure API Management fronting Azure Speech text-to-speech (REST) - POC
// =============================================================================
// Deploys:
//   - Log Analytics workspace + Application Insights (for APIM request/response logging)
//   - Azure AI Speech resource (Cognitive Services, kind=SpeechServices) with a
//     custom subdomain (required for Microsoft Entra ID authentication)
//   - Azure API Management (Basic v2 SKU - fast to deploy, supports managed identity)
//   - System-assigned managed identity on APIM
//   - RBAC role assignment: "Cognitive Services Speech User" for the APIM identity,
//     scoped to just the Speech resource (least privilege)
//   - APIM backend pointing at the Speech custom-subdomain endpoint
//   - APIM API + POST /speech/synthesize operation with the policy in apim/policy.xml
//   - APIM Application Insights logger + diagnostic setting
//
// This is a public-endpoint proof of concept: no VNet integration, private
// endpoints, or network isolation is configured. Do not use this as-is for
// production workloads that require network isolation.
// =============================================================================

@description('Short, unique suffix appended to resource names to avoid collisions (e.g. "demo01").')
param nameSuffix string = uniqueString(resourceGroup().id)

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the Azure API Management instance.')
param apimServiceName string = 'apim-speech-${nameSuffix}'

@description('Publisher name shown in the APIM developer portal.')
param apimPublisherName string = 'Contoso Speech Demo'

@description('Publisher email used by APIM for service notifications.')
param apimPublisherEmail string = 'admin@contoso.com'

@description('Name of the Azure AI Speech (Cognitive Services) resource. Also used as the custom subdomain, so it must be globally unique, lowercase, and alphanumeric/hyphen only.')
param speechAccountName string = 'speech-${nameSuffix}'

@description('SKU for the Speech resource. S0 is the standard pay-as-you-go tier.')
param speechSku string = 'S0'

@description('Name of the Log Analytics workspace used by Application Insights.')
param logAnalyticsName string = 'law-speech-${nameSuffix}'

@description('Name of the Application Insights instance used to log APIM requests/responses.')
param appInsightsName string = 'appi-speech-${nameSuffix}'

@description('Disable Speech resource API-key authentication entirely, forcing Microsoft Entra ID (managed identity) as the only auth path. Set to false if you need the key temporarily for troubleshooting.')
param disableSpeechLocalAuth bool = true

@description('APIM SKU. Basic v2 deploys faster than Developer/Premium and supports managed identity + VNet-less public access, ideal for this demo.')
param apimSkuName string = 'Basicv2'

@description('APIM SKU capacity (scale units).')
param apimSkuCapacity int = 1

@description('API version for the Azure Speech Batch synthesis (long-form/async) REST API.')
param speechBatchApiVersion string = '2024-04-01'

// -----------------------------------------------------------------------------
// Log Analytics + Application Insights
// -----------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
  }
}

// -----------------------------------------------------------------------------
// Azure AI Speech resource
// -----------------------------------------------------------------------------

resource speechAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: speechAccountName
  location: location
  kind: 'SpeechServices'
  sku: {
    name: speechSku
  }
  identity: {
    type: 'None'
  }
  properties: {
    // Required for Microsoft Entra ID authentication - regional endpoints do not support it.
    customSubDomainName: speechAccountName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: disableSpeechLocalAuth
  }
}

// -----------------------------------------------------------------------------
// Azure API Management (Basic v2)
// -----------------------------------------------------------------------------

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimServiceName
  location: location
  sku: {
    name: apimSkuName
    capacity: apimSkuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: apimPublisherName
    publisherEmail: apimPublisherEmail
  }
}

// -----------------------------------------------------------------------------
// RBAC: grant APIM's managed identity the "Cognitive Services Speech User" role
// scoped only to the Speech resource (least privilege).
// -----------------------------------------------------------------------------

var cognitiveServicesSpeechUserRoleId = 'f2dc8367-1007-4938-bd23-fe263f013447'

resource speechRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(speechAccount.id, apim.id, cognitiveServicesSpeechUserRoleId)
  scope: speechAccount
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesSpeechUserRoleId)
  }
}

// -----------------------------------------------------------------------------
// Named value exposing the Speech resource's ARM resource ID to the policy.
// This is NOT a secret - it is only the ARM resource ID string, required because
// the Speech REST API's Microsoft Entra ID auth expects the bearer token to be
// composed as "aad#<speech-resource-id>#<entra-access-token>" (see README for the
// Microsoft Learn reference). Storing it as a named value keeps the policy XML
// free of hardcoded resource identifiers.
// -----------------------------------------------------------------------------

resource speechResourceIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'speech-resource-id'
  properties: {
    displayName: 'speech-resource-id'
    value: speechAccount.id
    secret: false
  }
}

resource speechBatchApiVersionNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'speech-batch-api-version'
  properties: {
    displayName: 'speech-batch-api-version'
    value: speechBatchApiVersion
    secret: false
  }
}

// -----------------------------------------------------------------------------
// APIM backend pointing at the Speech REGIONAL text-to-speech endpoint.
//
// IMPORTANT (verified empirically against the live service, since Microsoft's REST
// TTS documentation page reuses a Speech-to-text sample that is misleading for TTS):
// the "Convert text to speech" REST call (POST /cognitiveservices/v1) must be sent to
// the REGIONAL host (https://<region>.tts.speech.microsoft.com), NOT the resource's
// custom-subdomain host. The custom subdomain is still required on the resource
// (Microsoft Entra ID auth cannot be issued/used at all without it), but the
// synthesis call itself 404s on the custom-subdomain host and only succeeds on the
// regional host - and only when the bearer token uses the composed
// "aad#<resourceId>#<entraToken>" format (a plain Entra bearer token is rejected
// with 401 on the regional host). See apim/policy.xml and README.md for details.
// -----------------------------------------------------------------------------

resource speechBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'speech-backend'
  properties: {
    title: 'Azure Speech Text-to-Speech'
    description: 'Azure AI Speech text-to-speech REST endpoint (regional host), authenticated via Microsoft Entra ID using the composed aad# token format.'
    url: 'https://${location}.tts.speech.microsoft.com'
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// -----------------------------------------------------------------------------
// APIM backend for the Speech BATCH SYNTHESIS (async, long-form text) REST API.
//
// Unlike the real-time /cognitiveservices/v1 synthesis call, batch synthesis:
//   - is served from the resource's CUSTOM-SUBDOMAIN host (not the regional host)
//   - accepts a PLAIN Microsoft Entra bearer token (no "aad#<resourceId>#" composition)
// Both facts were verified against the current Microsoft Learn Batch synthesis API
// docs (the real-time endpoint's regional-host/composed-token requirement does NOT
// apply here). See apim/policy-batch-*.xml and README.md for details.
// -----------------------------------------------------------------------------

resource speechBatchBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'speech-batch-backend'
  properties: {
    title: 'Azure Speech Batch Synthesis'
    description: 'Azure AI Speech Batch synthesis (async, long-form text-to-speech) REST endpoint on the custom-subdomain host, authenticated via Microsoft Entra ID with a plain bearer token.'
    url: 'https://${speechAccount.properties.customSubDomainName}.cognitiveservices.azure.com'
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

// -----------------------------------------------------------------------------
// Application Insights logger + diagnostic settings for APIM (request/response logging)
// -----------------------------------------------------------------------------

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for the Speech demo API'
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
    resourceId: appInsights.id
  }
}

resource apimDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    loggerId: apimLogger.id
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    frontend: {
      request: {
        headers: []
        body: {
          bytes: 512
        }
      }
      response: {
        headers: [
          'Content-Type'
          'Content-Length'
        ]
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: {
        headers: [
          'Content-Type'
          'Content-Length'
        ]
        body: {
          bytes: 0
        }
      }
    }
  }
}

// -----------------------------------------------------------------------------
// APIM API + operation + policy
// -----------------------------------------------------------------------------

resource speechApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'speech-api'
  properties: {
    displayName: 'Speech Text-to-Speech Demo API'
    description: 'Demo API that proxies text-to-speech requests to Azure AI Speech via Microsoft Entra ID / managed identity.'
    path: 'speech'
    protocols: [
      'https'
    ]
    subscriptionRequired: true
  }
}

resource speechSynthesizeOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'synthesize'
  properties: {
    displayName: 'Synthesize speech from text'
    method: 'POST'
    urlTemplate: '/synthesize'
    request: {
      description: 'JSON body with the text to synthesize.'
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 200
        description: 'Synthesized audio.'
        representations: [
          {
            contentType: 'audio/wav'
          }
        ]
      }
    ]
  }
  dependsOn: [
    speechBackend
  ]
}

resource speechSynthesizePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: speechSynthesizeOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policy.xml')
  }
  dependsOn: [
    speechResourceIdNamedValue
  ]
}

// -----------------------------------------------------------------------------
// Batch synthesis (async, long-form text) operations: create / status / delete.
// See apim/policy-batch-*.xml for the policy details and README.md for the
// auth/host differences vs. the real-time /speech/synthesize operation.
// -----------------------------------------------------------------------------

resource speechBatchCreateOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'batch-synthesize-create'
  properties: {
    displayName: 'Submit a batch (long-form) synthesis job'
    method: 'PUT'
    urlTemplate: '/batch/synthesize/{id}'
    templateParameters: [
      {
        name: 'id'
        type: 'string'
        required: true
        description: 'Unique job id (3-64 chars, alphanumeric/./_/- , must start and end with alphanumeric).'
      }
    ]
    request: {
      description: 'JSON body with the text to synthesize (same shape as /speech/synthesize).'
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 201
        description: 'Batch synthesis job created; JSON body reports job status.'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
  dependsOn: [
    speechBatchBackend
  ]
}

resource speechBatchCreatePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: speechBatchCreateOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policy-batch-create.xml')
  }
  dependsOn: [
    speechBatchApiVersionNamedValue
  ]
}

resource speechBatchStatusOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'batch-synthesize-status'
  properties: {
    displayName: 'Get batch synthesis job status/result'
    method: 'GET'
    urlTemplate: '/batch/synthesize/{id}'
    templateParameters: [
      {
        name: 'id'
        type: 'string'
        required: true
        description: 'Job id previously used to create the batch synthesis job.'
      }
    ]
    responses: [
      {
        statusCode: 200
        description: 'Job status JSON. When status is "Succeeded", outputs.result is a direct SAS URL to the audio.'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
  dependsOn: [
    speechBatchBackend
  ]
}

resource speechBatchStatusPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: speechBatchStatusOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policy-batch-status.xml')
  }
  dependsOn: [
    speechBatchApiVersionNamedValue
  ]
}

resource speechBatchDeleteOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: speechApi
  name: 'batch-synthesize-delete'
  properties: {
    displayName: 'Delete a batch synthesis job'
    method: 'DELETE'
    urlTemplate: '/batch/synthesize/{id}'
    templateParameters: [
      {
        name: 'id'
        type: 'string'
        required: true
        description: 'Job id to delete, including its Microsoft-managed output storage.'
      }
    ]
    responses: [
      {
        statusCode: 204
        description: 'Job deleted.'
      }
    ]
  }
  dependsOn: [
    speechBatchBackend
  ]
}

resource speechBatchDeletePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: speechBatchDeleteOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../apim/policy-batch-delete.xml')
  }
  dependsOn: [
    speechBatchApiVersionNamedValue
  ]
}

// -----------------------------------------------------------------------------
// Product + subscription for testing
// -----------------------------------------------------------------------------

resource speechProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'speech-demo-product'
  properties: {
    displayName: 'Speech Demo Product'
    description: 'Product grouping the Speech text-to-speech demo API.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource speechProductApiLink 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: speechProduct
  name: speechApi.name
}

resource speechSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'speech-demo-subscription'
  properties: {
    displayName: 'Speech Demo Test Subscription'
    scope: speechProduct.id
    state: 'active'
  }
  dependsOn: [
    speechProductApiLink
  ]
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------

output apimGatewayUrl string = apim.properties.gatewayUrl
output apimName string = apim.name
output speechAccountName string = speechAccount.name
output speechCustomSubdomain string = speechAccount.properties.customSubDomainName
output appInsightsName string = appInsights.name
output apimManagedIdentityPrincipalId string = apim.identity.principalId
output speechSynthesizeUrl string = '${apim.properties.gatewayUrl}/speech/synthesize'
output speechBatchSynthesizeUrlBase string = '${apim.properties.gatewayUrl}/speech/batch/synthesize'
