#!/usr/bin/env bash
# =============================================================================
# Tests the deployed APIM Speech synthesize endpoint end-to-end using curl.
#
# Usage:
#   ./scripts/test.sh <resource-group-name> [apim-service-name] [output-file] \
#       [--text "..."] [--voice en-US-JennyNeural] [--language en-US]
#
# Looks up the APIM gateway URL and the demo subscription key automatically,
# then POSTs sample JSON text and saves the returned audio locally.
#
# A few popular neural voices (see README.md for how to list ALL supported
# voices via the Speech "voices/list" REST endpoint):
#   en-US-JennyNeural     en-US, female   (default)
#   en-US-GuyNeural       en-US, male
#   en-US-AriaNeural      en-US, female
#   en-GB-SoniaNeural     en-GB, female
#   en-GB-RyanNeural      en-GB, male
#   es-ES-ElviraNeural    es-ES, female
#   fr-FR-DeniseNeural    fr-FR, female
#   de-DE-KatjaNeural     de-DE, female
#   ja-JP-NanamiNeural    ja-JP, female
#   zh-CN-XiaoxiaoNeural  zh-CN, female
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${1:?Usage: test.sh <resource-group-name> [apim-service-name] [output-file] [--text \"...\"] [--voice NAME] [--language LOCALE]}"
shift

APIM_NAME=""
OUTPUT_FILE="output.wav"
TEXT="Hello, this is a test of Azure Speech through Azure API Management."
VOICE=""
LANGUAGE=""

# First two remaining positional args (if present and not flags) are apim-name and output-file,
# for backward compatibility with the original positional-only usage.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)
      TEXT="$2"; shift 2 ;;
    --voice)
      VOICE="$2"; shift 2 ;;
    --language)
      LANGUAGE="$2"; shift 2 ;;
    *)
      if [[ -z "${APIM_NAME}" ]]; then
        APIM_NAME="$1"
      elif [[ "${OUTPUT_FILE}" == "output.wav" ]]; then
        OUTPUT_FILE="$1"
      fi
      shift ;;
  esac
done

if [[ -z "${APIM_NAME}" ]]; then
  echo "==> Discovering APIM service in resource group '${RESOURCE_GROUP}'..."
  APIM_NAME=$(az apim list --resource-group "${RESOURCE_GROUP}" --query "[0].name" -o tsv)
fi

if [[ -z "${APIM_NAME}" ]]; then
  echo "ERROR: could not find an APIM service in resource group '${RESOURCE_GROUP}'." >&2
  exit 1
fi

echo "==> Using APIM service: ${APIM_NAME}"
GATEWAY_URL=$(az apim show --name "${APIM_NAME}" --resource-group "${RESOURCE_GROUP}" --query "gatewayUrl" -o tsv)

echo "==> Fetching demo subscription key..."
SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
SUB_KEY=$(az rest --method post \
  --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/speech-demo-subscription/listSecrets?api-version=2024-05-01" \
  --query "primaryKey" -o tsv)

# Build the JSON body, only including voice/language if the caller supplied them.
JSON_BODY=$(python3 -c "
import json, sys
body = {'text': sys.argv[1]}
if sys.argv[2]:
    body['voice'] = sys.argv[2]
if sys.argv[3]:
    body['language'] = sys.argv[3]
print(json.dumps(body))
" "${TEXT}" "${VOICE}" "${LANGUAGE}")

echo "==> Gateway URL: ${GATEWAY_URL}"
echo "==> Calling POST ${GATEWAY_URL}/speech/synthesize"
echo "==> Request body: ${JSON_BODY}"

HTTP_STATUS=$(curl -sS -o "${OUTPUT_FILE}" -w "%{http_code}" \
  -X POST "${GATEWAY_URL}/speech/synthesize" \
  -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
  -H "Content-Type: application/json" \
  -d "${JSON_BODY}")

echo "==> HTTP status: ${HTTP_STATUS}"

if [[ "${HTTP_STATUS}" == "200" ]]; then
  echo "==> Success! Audio saved to: ${OUTPUT_FILE}"
  file "${OUTPUT_FILE}" 2>/dev/null || true
  afplay ${OUTPUT_FILE}
else
  echo "==> Request failed. Response body:" >&2
  cat "${OUTPUT_FILE}" >&2
  exit 1
fi
