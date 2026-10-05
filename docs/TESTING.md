# Testing Reference (Appendix)

The main [README](../README.md) covers the quickest way to test this demo (the provided scripts/clients).
This file has the manual/raw equivalents and the full troubleshooting table, for when you want to see
exactly what's happening on the wire or need to debug something not covered by the quickstart.

---

## Real-time: exact curl commands (no script)

```bash
GATEWAY_URL=$(az apim show --name <apim-name> --resource-group <rg> --query "gatewayUrl" -o tsv)
SUB_KEY=$(az rest --method post \
  --uri "https://management.azure.com/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim-name>/subscriptions/speech-demo-subscription/listSecrets?api-version=2024-05-01" \
  --query "primaryKey" -o tsv)

curl -X POST "${GATEWAY_URL}/speech/synthesize" \
  -H "Ocp-Apim-Subscription-Key: ${SUB_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello, this is a test of Azure Speech through Azure API Management."}' \
  --output output.wav -w "HTTP %{http_code}\n"
```

Play the result, e.g. on macOS: `afplay output.wav`.

## Batch synthesis: exact curl commands (no script)

```bash
# 1. Submit
curl -X PUT "$GATEWAY_URL/speech/batch/synthesize/my-job-1" \
  -H "Ocp-Apim-Subscription-Key: $SUB_KEY" -H "Content-Type: application/json" \
  -d '{"text":"Long-form text here."}'

# 2. Poll (repeat until "status":"Succeeded")
curl "$GATEWAY_URL/speech/batch/synthesize/my-job-1" -H "Ocp-Apim-Subscription-Key: $SUB_KEY"

# 3. Download the result directly (URL comes from the poll response's outputs.result) and unzip it
curl -o result.zip "<outputs.result SAS URL from step 2>"
unzip result.zip   # produces 0001.wav, 0001.debug.json, summary.json

# 4. Clean up
curl -X DELETE "$GATEWAY_URL/speech/batch/synthesize/my-job-1" -H "Ocp-Apim-Subscription-Key: $SUB_KEY"
```

---

## Listing every available voice

`scripts/test.sh` and the README's quick table only show a handful of popular voices. To list **every**
voice available to your Speech resource (name, gender, locale, supported styles), call the Speech REST
"voices list" endpoint directly with an access token (see [Get a list of
voices](https://learn.microsoft.com/azure/ai-services/speech-service/rest-text-to-speech#get-a-list-of-voices)):

```bash
TOKEN=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv)
curl -s "https://<speech-account-name>.cognitiveservices.azure.com/tts/cognitiveservices/voices/list" \
  -H "Authorization: Bearer ${TOKEN}" | python3 -m json.tool | less
```

> Note: this requires your own account (or whoever runs the command) to also have the
> `Cognitive Services Speech User` role on the Speech resource - APIM's managed identity has it by
> default, but your personal login likely does not. Grant it temporarily with
> `az role assignment create --assignee <your-upn-or-object-id> --role "Cognitive Services Speech User" --scope <speech-resource-id>`
> if you want to run this yourself, and remove it afterward.

---

## Viewing logs in Application Insights

The `appi-speech-*` Application Insights instance (linked to a `law-speech-*` Log Analytics workspace)
receives APIM request/response diagnostics. In the Azure portal, open the Application Insights resource
-> **Logs**, and query, e.g.:

```kusto
requests
| where cloud_RoleName == "<apim-name>"
| order by timestamp desc
| take 50
```

---

## Full Troubleshooting Table

| Symptom | Likely cause | Fix |
|---|---|---|
| `502` with `"error":"backend_authentication_failed"` | APIM managed identity role assignment hasn't propagated yet, or wasn't created | Wait 5-10 minutes after deployment and retry. Verify with `az role assignment list --assignee <apim-principal-id> --scope <speech-resource-id>`. |
| `404 Resource not found` from the Speech backend (not APIM's own 404) | The synthesis call was sent to the custom-subdomain host instead of the regional host, or the `Authorization` header used a plain bearer token instead of the composed `aad#<resourceId>#<token>` format | Confirm `speech-backend`'s URL is the regional host (`https://<region>.tts.speech.microsoft.com`) and that the policy sets the composed Authorization header correctly - see [AUTHENTICATION.md](AUTHENTICATION.md) for the verified requirement. |
| `401 Unauthorized` from Speech | Custom subdomain missing/misconfigured, wrong token audience, or the `Authorization` header is missing the `aad#` composition on the regional host | Confirm the Speech resource has a custom subdomain (`az cognitiveservices account show --name <speech> --resource-group <rg> --query properties.customSubDomainName`), that the policy's `authentication-managed-identity resource` is exactly `https://cognitiveservices.azure.com`, and that the token is composed as described above. |
| `400 Bad Request` from APIM | Missing/empty `text` field, or malformed JSON | Confirm your request body is `{"text": "..."}`. Check the JSON error message returned by the policy. |
| `415 Unsupported Media Type` from Speech | `Content-Type` not exactly `application/ssml+xml` reaching the backend | Confirm you haven't overridden the policy's `Content-Type` header downstream of the SSML build step. |
| `403` calling `az deployment group create` for the role assignment | Your account lacks `Microsoft.Authorization/roleAssignments/write` | Ask a subscription/RG `Owner` (or `User Access Administrator`) to run the deployment, or grant you that role. |
| `401` returned by APIM itself (not the backend) | Wrong/missing `Ocp-Apim-Subscription-Key` | Re-fetch the subscription key (see README "Testing" section); the API has `subscriptionRequired: true`. |
| Audio file won't play | Wrong output format requested, or truncated download | Try the default `riff-24khz-16bit-mono-pcm` (WAV) output format; verify the byte count printed by the test client matches the file size on disk. |
| Slow first deployment | Basic v2 still provisioning | Basic v2 is faster than Developer/Premium but still takes ~10-20 minutes; this is expected. |
| Batch job `status` stuck on `"Running"` | Normal for larger inputs - synthesis is asynchronous and can take longer than a single real-time call | Keep polling `GET /speech/batch/synthesize/{id}`; `scripts/test-batch.sh` and `client/test_batch_tts.py` both poll automatically (default timeout 300s for the Python client). |
| Batch job `status` is `"Failed"` | Malformed SSML, unsupported voice/locale combination, or a transient backend error | Inspect the full status JSON body for `properties.billingDetails`/error details; retry with a known-good voice. |
| `404`/`401` from the **batch** backend specifically | Using the real-time endpoint's rules by mistake - batch synthesis needs the **custom-subdomain host** and a **plain** bearer token (no `aad#` composition) | Confirm `speech-batch-backend`'s URL is `https://<speech-name>.cognitiveservices.azure.com` and that `policy-batch-*.xml` set `Authorization: Bearer <token>` directly - see [AUTHENTICATION.md](AUTHENTICATION.md). |
| Batch result download (`curl outputs.result`) fails with `403`/expired signature | The SAS URL in the status JSON is time-limited and regenerated on each poll | Re-fetch the status (`GET /speech/batch/synthesize/{id}`) to get a fresh `outputs.result` URL, then download immediately. |
