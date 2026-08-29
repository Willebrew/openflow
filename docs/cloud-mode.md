# OpenFlow Cloud Mode

## Goal

openflow Pro lets users subscribe instead of bringing their own Groq API key.
The macOS app authenticates with NeuroQuest Labs Auth and calls the openflow
cloud HTTP API for entitlement, transcription, cleanup, and billing.

This repository is the Mac client only. The cloud service is not published here.

## Provider Modes

- `localGroq`: Mac calls Groq with the Keychain key. No subscription required.
- `openflowCloud`: Cloud transcription using a server-side Groq credential.
- A stored BYO key always wins: Whisper and cleanup skip the cloud even if the
  user is signed in or entitled. Optional `POST /openflow/activity` still runs
  when they have a session.

The subscription page lets the user sign in, subscribe, manage billing, or
choose the separate bring-your-own-key path.

## Auth Flow

The macOS app uses the NQL Auth device-code flow in `CloudAuthService`. There is
no `/api/sso/exchange` or `/api/sso/jwt` step.

1. App `POST`s `https://auth.neuroquestlabs.ai/api/openflow/device/start` with
   the Mac's device name.
2. Auth returns a device code, user code, verification URI, expiry, and poll
   interval.
3. App runs `CloudURLPolicy.validate` on `verificationUriComplete` (or
   `verificationUri`) with usage `.deviceVerification` before opening it.
4. App opens that URL with `CloudURLPolicy.openExternal` so the user can confirm
   the code in the browser.
5. App `POST`s `/api/openflow/device/token` at the server interval until a
   terminal state:
   - `202` pending: keep polling
   - `2xx` with a session token: store the token in Keychain and finish
   - any other status: fail with the server error message
   - deadline from `expiresIn` reached: fail as expired
6. Cancellation of the Swift task aborts polling without storing a token.

## Remote session revocation

Website account settings delete the NQL Auth session immediately. The Mac
revalidates the stored Keychain token with
`POST https://auth.neuroquestlabs.ai/api/openflow/introspect` (Bearer token,
`{"product":"openflow"}`) at launch before signed-in UI, when the app becomes
active, on system wake, and every 12 minutes.

- `401` or `{active:false}`: `CloudAuthService.signOut()` /
  `KeychainService.deleteCloudTokens()` only. BYO Groq (`openflow.groq`) stays.
  Signed-in surfaces flip off. Message: “Your session was signed out from your
  account settings. Sign in again to use openflow cloud.”
- Transport errors and non-401 HTTP: **indeterminate**. No state change.
  Airplane mode works as before.
- Authenticated cloud `401` while a token was present uses the same revoked
  path (`OpenflowError.cloudSessionRevoked`). Missing token stays
  `cloudAuthenticationRequired` so sign-in prompts still make sense.

## Cloud HTTP routes the Mac calls

The production site URL is configured in `UserSettings`. Routes include:

- `GET /openflow/entitlement`
- `POST /openflow/audio-upload-url`
- `POST /openflow/transcribe`
- `POST /openflow/cleanup`
- `POST /openflow/generate-style` (Pro only on the server-key path)
- `POST /openflow/billing/checkout`
- `POST /openflow/billing/portal`

`POST /openflow/generate-style` is Pro-only on the server-key path. Free
accounts write a style themselves. A stored BYO Groq key generates on the Mac
for any plan and does not call this route.

## Server-Provided URL Trust

Every URL that arrives in a backend or auth-server response is untrusted input.
`CloudURLPolicy.validate` requires https, no embedded credentials, and a host on
the usage-specific allowlist plus the configured backend host, and it guards the
device-flow verification link, the Stripe checkout and portal links, and the
audio upload reservation. `CloudURLPolicy.openExternal` re-checks the scheme at
the `NSWorkspace` sink, so no code path can launch a `file://` bundle or a custom
scheme handler from a server response. Adding a new backend-provided link means
extending the allowlist, never bypassing the policy;
`scripts/verify-production-readiness.sh` enforces both halves.

## Stripe (client)

- Checkout and the customer portal open from URLs returned by the cloud API.
- Those links must pass `CloudURLPolicy` before `NSWorkspace` opens them.
- Transcription and cleanup require an active entitlement. Billing routes may
  be used while signed in without an active cloud entitlement.

## Privacy Defaults

- Local mode sends audio/transcript directly to Groq using the user's key.
- Cloud mode proxies through NeuroQuest/OpenFlow infrastructure.
- Cloud mode stores usage/error/latency metadata only.
- Cloud mode does not retain audio or transcript text unless a future explicit opt-in debug feature is designed.
- Cloud cleanup requests include the transcript plus any selected text and nearby text as context.
