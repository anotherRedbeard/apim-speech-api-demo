using './main.bicep'

param location = 'eastus'

// Must be globally unique across Azure - change before deploying.
param nameSuffix = 'demo01'

param apimServiceName = 'apim-speech-demo01'
param apimPublisherName = 'Contoso Speech Demo'
param apimPublisherEmail = 'admin@contoso.com'

// Must be globally unique - becomes https://<speechAccountName>.cognitiveservices.azure.com
param speechAccountName = 'speech-demo01'
param speechSku = 'S0'

param logAnalyticsName = 'law-speech-demo01'
param appInsightsName = 'appi-speech-demo01'

// Enforces Microsoft Entra ID (managed identity) only - no Speech resource key auth.
param disableSpeechLocalAuth = true

// Basic v2 - fast to deploy, supports managed identity, no VNet required for this demo.
param apimSkuName = 'Basicv2'
param apimSkuCapacity = 1
