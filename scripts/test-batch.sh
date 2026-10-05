#!/usr/bin/env bash
# =============================================================================
# Tests the deployed APIM Speech BATCH synthesis endpoints end-to-end using curl.
#
# Unlike scripts/test.sh (real-time, single request/response), this exercises
# the async job workflow:
#   1. PUT    /speech/batch/synthesize/{job-id}   - submit the job
#   2. GET    /speech/batch/synthesize/{job-id}   - poll until status is terminal
#   3. curl the "outputs.result" SAS URL directly (Microsoft-managed storage,
#      NOT proxied through APIM - see README.md for why) and unzip the .wav
#   4. DELETE /speech/batch/synthesize/{job-id}   - clean up the job (optional)
#
# Usage:
#   ./scripts/test-batch.sh <resource-group-name> [apim-service-name] [output-file] \
#       [--text "..."] [--voice en-US-JennyNeural] [--language en-US] [--keep-job]
#
# See scripts/test.sh for the list of popular voice names.
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${1:?Usage: test-batch.sh <resource-group-name> [apim-service-name] [output-file] [--text \"...\"] [--voice NAME] [--language LOCALE] [--keep-job]}"
shift

APIM_NAME=""
OUTPUT_FILE="batch_output.wav"
TEXT="This is a test of the Azure Speech Batch synthesis API through Azure API Management."
VOICE=""
LANGUAGE=""
KEEP_JOB="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)
      TEXT="$2"; shift 2 ;;
    --voice)
      VOICE="$2"; shift 2 ;;
    --language)
      LANGUAGE="$2"; shift 2 ;;
    --keep-job)
      KEEP_JOB="true"; shift ;;
    *)
      if [[ -z "${APIM_NAME}" ]]; then
        APIM_NAME="$1"
      elif [[ "${OUTPUT_FILE}" == "batch_output.wav" ]]; then
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

JOB_ID="apim-speech-demo-$(date +%s)"
JOB_URL="${GATEWAY_URL}/speech/batch/synthesize/${JOB_ID}"

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
echo "==> Job id: ${JOB_ID}"
echo "==> Submitting PUT ${JOB_URL}"
echo "==> Request body: ${JSON_BODY}"

CREATE_STATUS=$(curl -sS -o /tmp/apim-speech-batch-create.json -w "%{http_code}" \
  -X PUT "${JOB_URL}" \
  -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
  -H "Content-Type: application/json" \
  -d "${JSON_BODY}")

echo "==> Create HTTP status: ${CREATE_STATUS}"
if [[ "${CREATE_STATUS}" != "201" ]]; then
  echo "==> Job creation failed. Response body:" >&2
  cat /tmp/apim-speech-batch-create.json >&2
  exit 1
fi

echo "==> Polling job status..."
STATUS="Running"
for _ in $(seq 1 60); do
  sleep 3
  curl -sS -o /tmp/apim-speech-batch-status.json \
    -X GET "${JOB_URL}" \
    -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}"
  STATUS=$(python3 -c "import json;print(json.load(open('/tmp/apim-speech-batch-status.json')).get('status','Unknown'))")
  echo "    ... status: ${STATUS}"
  if [[ "${STATUS}" == "Succeeded" || "${STATUS}" == "Failed" ]]; then
    break
  fi
done

if [[ "${STATUS}" != "Succeeded" ]]; then
  echo "==> Job did not succeed (final status: ${STATUS}). Full status body:" >&2
  cat /tmp/apim-speech-batch-status.json >&2
  exit 1
fi

RESULT_URL=$(python3 -c "import json;print(json.load(open('/tmp/apim-speech-batch-status.json'))['outputs']['result'])")
echo "==> Downloading result archive directly from Microsoft-managed storage (not via APIM)..."
curl -sS -o /tmp/apim-speech-batch-result.zip "${RESULT_URL}"

echo "==> Extracting audio to ${OUTPUT_FILE}..."
python3 -c "
import zipfile
with zipfile.ZipFile('/tmp/apim-speech-batch-result.zip') as z:
    wav_name = next(n for n in z.namelist() if n.lower().endswith('.wav'))
    with z.open(wav_name) as src, open('${OUTPUT_FILE}', 'wb') as dst:
        dst.write(src.read())
"

echo "==> Success! Audio saved to: ${OUTPUT_FILE}"
file "${OUTPUT_FILE}" 2>/dev/null || true

if [[ "${KEEP_JOB}" == "false" ]]; then
  echo "==> Cleaning up: DELETE ${JOB_URL}"
  DELETE_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "${JOB_URL}" -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}")
  echo "==> Delete HTTP status: ${DELETE_STATUS}"
else
  echo "==> --keep-job set; job left in place (id: ${JOB_ID})."
fi

rm -f /tmp/apim-speech-batch-create.json /tmp/apim-speech-batch-status.json /tmp/apim-speech-batch-result.zip
