#!/usr/bin/env bash
# =============================================================================
# Deploys the APIM + Azure Speech proof-of-concept described in infra/main.bicep.
#
# Usage:
#   ./scripts/deploy.sh <resource-group-name> [location]
#
# Prerequisites:
#   - Azure CLI logged in (az login) with an active subscription (az account set).
#   - Owner or User Access Administrator + Contributor rights on the target
#     subscription/resource group (role assignment on the Speech resource requires it).
#   - Edit infra/parameters.bicepparam to use globally-unique names before running.
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${1:-rg-apim-speech-demo}"
LOCATION="${2:-eastus}"
TEMPLATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/main.bicep"
PARAMS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/infra/parameters.bicepparam"
DEPLOYMENT_NAME="apim-speech-demo-$(date +%Y%m%d%H%M%S)"

echo "==> Ensuring resource group '${RESOURCE_GROUP}' exists in '${LOCATION}'..."
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

echo "==> Validating deployment..."
az deployment group validate \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${PARAMS_FILE}"

echo "==> Deploying (this can take 10-20 minutes for APIM Basic v2 to provision)..."
az deployment group create \
  --name "${DEPLOYMENT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${PARAMS_FILE}" \
  --output json > /tmp/"${DEPLOYMENT_NAME}".json

echo "==> Deployment complete. Key outputs:"
az deployment group show \
  --name "${DEPLOYMENT_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query properties.outputs

echo ""
echo "NOTE: RBAC role assignments can take a few minutes to propagate."
echo "If the first test call returns 401/403 from the Speech backend, wait ~5 minutes and retry."
echo ""
echo "Next steps:"
echo "  1. Fetch the APIM subscription key (see README.md 'Testing' section)."
echo "  2. Run ./scripts/test.sh <resource-group>"
