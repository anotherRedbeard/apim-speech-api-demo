# Authentication Deep Dive

This document covers the verified, non-obvious authentication requirements for calling Azure Speech's
REST APIs from Azure API Management using a managed identity. The main [README](../README.md) only
summarizes this; read this file if you're implementing something similar yourself, debugging an auth
failure, or just curious why the policies are written the way they are.

---

## Real-time synthesis (`POST /cognitiveservices/v1`)

Azure Speech's text-to-speech REST endpoint supports two authentication headers per the
[Speech REST API reference](https://learn.microsoft.com/azure/ai-services/speech-service/rest-text-to-speech):

| Header | Supported | Used here? |
|---|---|---|
| `Ocp-Apim-Subscription-Key` (resource key) | Yes | **No** - avoided to keep secrets out of APIM entirely |
| `Authorization` (`Bearer <token>`) | Yes | **Yes** - token obtained via APIM's managed identity |

This POC uses the `Authorization: Bearer` path, where the token is a **Microsoft Entra ID** access token
obtained through APIM's `authentication-managed-identity` policy - no Speech key is ever generated,
stored, or referenced by APIM. Verified requirements for this path (confirmed against the live service,
not just documentation - see callout below):

1. **Custom subdomain required.** Microsoft Entra ID token issuance for Cognitive Services/Speech only
   works when the resource has a **custom subdomain** configured
   (`https://<name>.cognitiveservices.azure.com`). The Bicep template sets `customSubDomainName` on the
   Speech resource for this reason.
2. **Token audience / resource.** The token must be requested for resource/audience
   `https://cognitiveservices.azure.com` (i.e. scope `https://cognitiveservices.azure.com/.default`).
   The policy uses `<authentication-managed-identity resource="https://cognitiveservices.azure.com" .../>`.
3. **Required RBAC role.** The identity calling Speech needs the built-in
   **`Cognitive Services Speech User`** role (`f2dc8367-1007-4938-bd23-fe263f013447`) on the Speech
   resource (or `Cognitive Services Speech Contributor` for management operations, not needed here). The
   Bicep template assigns this role to APIM's managed identity, scoped only to the Speech resource
   (least privilege).
4. **Composed token format required.** The `Authorization` header must carry a composed token:
   `Bearer aad#<speech-resource-ARM-id>#<entra-access-token>` (per the "Use Microsoft Entra
   authentication" section of the Speech REST API reference). A plain bearer token (just the raw Entra
   token) is rejected. The policy builds this string using a named value (`{{speech-resource-id}}`, set
   in Bicep to the Speech account's ARM resource ID - not a secret) concatenated with the token from
   `authentication-managed-identity`.
5. **The synthesis call must target the REGIONAL host, not the custom-subdomain host.**

   > **Verified-against-live-service correction:** Microsoft's TTS REST documentation page currently
   > illustrates its Microsoft Entra ID example by reusing a **Speech-to-text** sample request whose
   > `Host` header is the custom-subdomain endpoint. In practice, for the **text-to-speech**
   > `/cognitiveservices/v1` call, the custom-subdomain host (`https://<name>.cognitiveservices.azure.com`)
   > returns `HTTP 404` regardless of token format, while the **regional** host
   > (`https://<region>.tts.speech.microsoft.com`) returns `HTTP 200` when given the composed token
   > described above (and `HTTP 401` with a plain bearer token). This was confirmed by direct testing
   > against a deployed Speech resource, including cross-checking with the resource's own advertised
   > `endpoints` map (via `az resource show`), which lists `"Speech Services Text to Speech (Neural)"` as
   > the regional host even though a custom subdomain is configured. The custom subdomain is still
   > required (it's what enables Entra ID token issuance/scoping for the resource in the first place) -
   > it's simply not the host you send the synthesis `POST` to. The Bicep template's `speech-backend`
   > therefore points at `https://<region>.tts.speech.microsoft.com`, and the policy still builds the
   > composed token described above. If Microsoft updates the endpoint behavior or documentation,
   > re-verify before relying on this in production.

Because Speech's REST auth model doesn't support Entra ID for every possible Speech feature (e.g. some
older/regional-only endpoints), the general documented, secure alternative when managed identity truly
cannot be used is to store the Speech key in **Azure Key Vault** and reference it from an APIM
**named value with Key Vault backing** (`keyVault` secret reference) rather than embedding it in policy
XML or source code. This demo does not need that fallback because the TTS REST endpoint fully supports
Entra ID auth (with the composed-token, regional-host nuances documented above).

---

## Batch synthesis API (different from real-time!)

The [Batch synthesis API](https://learn.microsoft.com/azure/ai-services/speech-service/batch-synthesis)
(`texttospeech/batchsyntheses/*`) also supports Microsoft Entra ID / managed identity, but with **two
important differences** from the real-time endpoint above (both confirmed against the live service in
this demo):

1. **Host:** Batch synthesis is served from the resource's **custom-subdomain host**
   (`https://<name>.cognitiveservices.azure.com`), not the regional `tts.speech.microsoft.com` host used
   by real-time synthesis.
2. **Token format:** The `Authorization` header is a **plain** bearer token (`Bearer <token>`) -
   there is **no** `aad#<resourceId>#` composition for this API, unlike the real-time endpoint.

Same RBAC role (`Cognitive Services Speech User`) works for both APIs, so no additional role assignment
was needed - `apim/policy-batch-create.xml`, `policy-batch-status.xml`, and `policy-batch-delete.xml`
simply call `authentication-managed-identity` and set the header directly, without the composed-token
step. The `speech-batch-backend` Bicep resource points at the custom-subdomain host accordingly.

### Why the Batch result download bypasses APIM

When a batch job succeeds, its status JSON includes `outputs.result` - the audio is not returned in the
status response body. By default (no customer storage account configured), Speech auto-manages the
output storage and `outputs.result` is a **full, time-limited SAS URL** pointing directly at Microsoft's
storage. The documented pattern is to download directly from that URL; there is no supported way to
"pull" that blob through APIM as part of the same request (APIM never sees the file - only a URL
string), and proxying it would require a third backend pointing at an arbitrary, ever-changing SAS host,
which adds complexity for no real benefit in this demo. Both `client/test_batch_tts.py` and
`scripts/test-batch.sh` download from that URL directly, then unzip the result locally (the result is a
`.zip` containing the `.wav` audio, a debug JSON, and a summary JSON - this is Speech's default packaging
when no destination container is configured).
