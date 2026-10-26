# Backend Load Notice

`BackendLoadMonitor` (`openflow/Services/BackendLoadMonitor.swift`) polls
`GET <cloud base>/status/load` while openflow is awake and shows a quiet notice
when the backend reports elevated or high load. It never interrupts dictation,
never surfaces an error, and never blocks on the request.

The payload and decision rules live in
`openflow/Services/BackendLoadStatus.swift`; the banner view is
`openflow/Views/BackendLoadNoticeView.swift`.

## Response contract

The endpoint returns JSON with a required `level` and optional `message` and
`updatedAt`:

```json
{"level":"high","message":"Busy right now","updatedAt":1710000000000}
```

- `level` must be exactly `normal`, `elevated`, or `high`. Any other value,
  missing field, or non-object body is dropped (`BackendLoadStatusDecoder.parse`
  returns nil).
- `message` is sanitized before display: newlines, tabs, and control characters
  collapse to spaces, the result is trimmed, and anything over 160 characters is
  cut to 157 plus an ellipsis. Blank messages fall back to the built-in copy
  (`BackendLoadNoticePolicy.highMessage` / `elevatedMessage`).
- `normal` always hides the notice, even when a message is present.
- `updatedAt` is accepted only as a number; a bad value does not invalidate a
  good `level`.

Anything that is not a trusted 2xx snapshot leaves the current notice
untouched: transport errors, 404, 5xx, and unreadable JSON all decode as
`BackendLoadFetchOutcome.unchanged`. The monitor never clears a notice because
a fetch failed.

## Poll schedule

`BackendLoadSchedule` owns the timing:

| Condition | Interval |
| --- | --- |
| Launch | 3 s initial delay |
| Active (activity within 5 min) | 60 s |
| Idle (no activity for 5+ min) | 5 min |
| Machine or screen asleep | no polling |

Dictation and app activation count as activity via `noteUserActivity`, which
drops an idle backoff back to the 60 s poll. Sleep and wake come from
`NSWorkspace` notifications; a wake refreshes immediately when a refresh was
deferred during sleep or the last fetch is stale.

Requests use an 8 s timeout on an ephemeral, `reloadIgnoringLocalCacheData`
session and send only `Accept: application/json`. The call is unauthenticated
and carries no session token.

## Opportunistic refresh

A slow or failing backend call is itself a hint of load. Every cloud call is
timed inside `OpenFlowCloudService.dataForLoadProbe` (the shared `send` path
and both audio upload paths), which feeds `BackendLoadSignals.note`:

- transport failure, HTTP 429, or HTTP >= 500 triggers a refresh,
- a call taking 8 s or longer (`slowRequestSeconds`) triggers a refresh,
- cancellation is ignored so teardown does not look like an outage.

Refreshes are debounced to one per 20 s
(`BackendLoadSchedule.opportunisticCooldown`) and deferred while asleep
(`refreshWhenAwake`). `BackendLoadSignals` is a lock-guarded hook so the cloud
client can ask for a refresh without knowing about the menu bar or the hub.

## Where the notice appears

- Hub header: `BackendLoadBanner` sits next to the logo in
  `SettingsView.topConsole` and animates in and out.
- Menu bar: the status item tooltip and accessibility label carry the notice
  text, and a disabled menu item shows it above Quit.
- Diagnostics: each change writes `backend load notice: <text>` or
  `backend load notice cleared` to `DiagnosticsLog`.

`BackendLoadNotice.accessibilityLabel` keeps the menu bar item readable as
"openflow" when hidden and "openflow, <text>" when a notice is up.

## URL trust

The poll URL is `cloudBase.appendingPathComponent("status/load")` where the
base is `UserSettings.cloudBaseURL` re-validated through
`CloudURLPolicy.validateServiceBaseURL` on every request, so a changed or
hostile stored URL cannot redirect the poll.

For local testing the defaults key `openflowBackendLoadStatusOverrideURL`
(`BackendLoadMonitor.overrideDefaultsKey`) supplies a full request URL instead
of the configured base. The override must parse as https with a non-empty host
and no embedded credentials, and still passes `CloudURLPolicy.validate` with
usage `.serviceBase` -- the allowlist check is not bypassed.

## Contract checks

`scripts/check-backend-load-status.swift` pins the decoder, reducer, schedule,
endpoint, and signal rules above. It is compiled with
`BackendLoadStatus.swift` by `scripts/ci-linux.sh` (macOS runners only) and by
`scripts/verify-production-readiness.sh` as part of the release gate.
