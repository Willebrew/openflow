# openflow Pro End-To-End Checklist

Run this from the Mac client after a signed-in Pro account is available. Do not
ship openflow Pro until every item has dated evidence. This checklist is
client-side only.

## Environment

- Official or locally signed Mac build with Microphone and Accessibility.
- No local Groq key for the cloud-path cases; a BYO key for the local-path case.
- A browser session that can complete NQL Auth device confirmation and Stripe
  Checkout when those steps are in scope.

## Verification

1. Sign in through the macOS app with no local Groq key.
2. Confirm unauthenticated cloud requests return HTTP 401.
3. Confirm signed-in but unsubscribed transcription is rejected before Groq.
4. Complete Stripe Checkout and verify Settings shows Pro entitlement.
5. Confirm transcription and cleanup work without a local Groq key.
6. Confirm expired or canceled subscriptions are rejected before Groq.
7. Confirm rate and monthly usage limits return HTTP 429 when exceeded.
8. Confirm a fourth Mac on the same account can transcribe; Home totals include
   that Mac. Usage cutoff still blocks transcribe when secret rails are hit.
9. Confirm local bring-your-own-key mode still validates and works.

## Evidence To Keep

- Date and release candidate version.
- Redacted NQL Auth subject id.
- App diagnostics without transcript or audio content.
