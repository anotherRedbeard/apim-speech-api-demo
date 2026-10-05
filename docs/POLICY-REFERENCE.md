# APIM Policy Reference

Step-by-step walkthroughs of what each policy XML file does. For the authentication specifics
referenced below (composed vs. plain bearer tokens, regional vs. custom-subdomain hosts), see
[AUTHENTICATION.md](AUTHENTICATION.md).

---

## Real-time: [`apim/policy.xml`](../apim/policy.xml) (`POST /speech/synthesize`)

1. **Backend routing** - `<set-backend-service backend-id="speech-backend" />` routes to the Speech
   regional text-to-speech endpoint defined as an APIM backend resource.
2. **Input validation** - parses the JSON body; returns `400 Bad Request` with a JSON error body if it's
   missing, malformed, or has no `text` field.
3. **JSON -> SSML transformation** - extracts `text` (required) plus optional `voice`, `language`, and
   `outputFormat`, XML-escapes the text, and builds the SSML document Speech's TTS REST endpoint requires
   (`<speak>...<voice>...</voice></speak>`).
4. **Strip caller secrets** - removes the inbound `Ocp-Apim-Subscription-Key` header so the client's APIM
   key is never forwarded to the Speech backend.
5. **Backend authentication** - `<authentication-managed-identity resource="https://cognitiveservices.azure.com" .../>`
   fetches a Microsoft Entra ID token for APIM's managed identity, then builds the composed token and
   sets the `Authorization` header to `Bearer aad#<resourceId>#<token>`.
6. **Required Speech headers** - sets `Content-Type: application/ssml+xml`, `X-Microsoft-OutputFormat`
   (default `riff-24khz-16bit-mono-pcm`, a WAV/PCM format that plays natively almost everywhere), and a
   `User-Agent`.
7. **Method/URI rewrite** - forces `POST` and rewrites the path to `/cognitiveservices/v1`, the documented
   Speech TTS REST path (on the regional backend host).
8. In `outbound`, the response (binary audio with its original `Content-Type`, e.g. `audio/x-wav`) is
   passed straight back to the client unmodified.
9. `on-error` returns a clean `502 Bad Gateway` JSON error body, with a specific message when the failure
   is the managed-identity token acquisition (likely an RBAC propagation delay or missing role
   assignment) versus a generic backend failure.

---

## Batch synthesis: [`policy-batch-create.xml`](../apim/policy-batch-create.xml) /
[`policy-batch-status.xml`](../apim/policy-batch-status.xml) /
[`policy-batch-delete.xml`](../apim/policy-batch-delete.xml)

Intentionally simpler than the real-time policy:

- **Create (`PUT`)** - same JSON input shape and validation as `/speech/synthesize` (`text` required,
  `voice`/`language`/`outputFormat` optional with the same defaults), builds the same SSML, then wraps it
  in the Batch synthesis request body (`inputKind: "SSML"`, `inputs: [...]`, `properties.outputFormat`).
  Authenticates with a **plain** Entra bearer token (see [AUTHENTICATION.md](AUTHENTICATION.md)) and
  rewrites the URI to `/texttospeech/batchsyntheses/{id}?api-version={{speech-batch-api-version}}`.
- **Status (`GET`)** - pure pass-through: authenticate, rewrite the URI, forward. Returns the job's
  status JSON (including `outputs.result` once `"status": "Succeeded"`).
- **Delete (`DELETE`)** - pure pass-through: authenticate, rewrite the URI, forward. Deletes the job and
  its Microsoft-managed output storage.

All three strip the caller's `Ocp-Apim-Subscription-Key` before forwarding, and share the same
`on-error` pattern as the real-time policy.
