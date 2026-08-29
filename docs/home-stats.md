# Home Stats (streak, total words, WPM)

The Flow Hub Home panel shows four numbers: a day streak, total words, average
words per minute, and a 28-day usage grid. All four are derived in
`openflow/Models/HomeActivityStats.swift` from two independent sources, so the
merge rules matter more than the arithmetic.

## Inputs

| Source | Where it comes from | Day keys |
| --- | --- | --- |
| Local history | `HistoryService.items` (`history.json`, capped at 300 items) | local calendar |
| Cloud activity | `GET /openflow/stats` via `OpenFlowCloudService.stats` | UTC |
| Local lifetime | `HistoryService.lifetimeWords` (`lifetime.json`) | none, running total |
| Cloud lifetime | `OpenFlowCloudStats.lifetime.words` | none, running total |

`SettingsView.activityDays` maps history items and `coordinator.cloudStats.days`
into `HomeActivityStats.aggregate(history:cloudDays:)`, which returns
`[HomeActivityDay]` sorted by `dayKey`.

Both stores live in `~/Library/Application Support/openflow/`:
`history.json` for the visible rows and `lifetime.json` for the counters.

## Local calendar days, cloud UTC days

`/openflow/stats` buckets activity with `toISOString().slice(0, 10)`, so a cloud
day key is a UTC date. Comparing those keys against `Calendar.current` dates
shifted west-of-UTC mornings onto the previous day and zeroed the streak, so
`localizedCloudDayKey` translates each cloud key before the merge:

1. Take UTC noon of the cloud day and format it in the user's time zone
   (`civilLocalDayKey`). Noon keeps a US morning on the same civil date.
2. If local history has no such day but does have the day that UTC midnight
   maps to (`previousLocalDayKey`, the previous local evening), fold onto that
   day instead of splitting one session across two grid cells.
3. Otherwise keep the civil key.

Merging then follows two rules:

- Two cloud UTC buckets that localize onto the same local day are summed --
  they are genuinely different events.
- A cloud day that collides with a local day is combined per field with `max`,
  not a sum, because cloud and local usually describe the *same* dictations and
  either side can be the more complete record.

## Streak

`consecutiveStreak(days:now:calendar:)` counts backward over local day keys. If
today has no activity it starts from yesterday, so a streak stays alive until
the local day actually ends instead of resetting at midnight. Two consecutive
missing days end the streak.

## Total words

Home's "Total words" is a lifetime, never-decreasing count:

```swift
HomeActivityStats.lifetimeWords(
    days: activityDays,                        // recent window
    cloudLifetime: coordinator.cloudStats.lifetimeWords,
    localLifetime: coordinator.history.lifetimeWords
)   // == max(totalWords(days:), max(cloudLifetime, localLifetime))
```

This is what keeps the number stable across the situations that used to shrink
it:

- The 300-item history cap dropping older rows.
- History being disabled -- `DictationCoordinator` still calls
  `HistoryService.recordLifetime(text:audioSeconds:)` on every completed
  dictation, and `clear()` does not touch `lifetime.json`.
- A cloud response returning a shorter window than the local high-water mark.
  `adoptLifetimeHighWater(words:)` only ever raises the local counter.

Words are counted with whitespace splitting (`wordCount(in:)`), so newlines and
runs of spaces do not inflate the count.

## WPM and the usage grid

- `averageWPM(days:)` is `totalWords / summed audioSeconds * 60` over the merged
  days, and returns `0` when either side is zero. It is a windowed average, not
  a lifetime one.
- `recentUsageOffsets(days:now:calendar:window:)` returns grid offsets in a
  trailing window where `window - 1` is today and `0` is the oldest cell. Home
  renders a 28-cell grid, so `dayLabel(offset:)` computes `27 - offset` days ago.

## Local-provider activity still reaches the cloud

`DictationCoordinator.syncLocalProviderActivityIfNeeded` posts word and audio
totals to `POST /openflow/activity` for dictations whose provider is *not*
`openflow-pro`, then refreshes `/openflow/stats`. Signed-in users therefore get
consistent Home stats across devices even while using their own Groq key.
Transcript text is never part of that payload.

## Constraints and pitfalls

- Never compare a cloud `dayKey` with a locally formatted date directly; go
  through `localizedCloudDayKey`.
- Never sum local and cloud counts for the same day, and never let a new code
  path lower `lifetime.words`.
- `dayFormatter` is deliberately `en_US_POSIX` + Gregorian; a locale-dependent
  formatter would produce keys that do not match the cloud format.

## Verification

`scripts/check-home-activity-stats.swift` covers the MDT morning streak case,
the pre-fix UTC regression, evening folding, cloud-only days, summed UTC
buckets, and the lifetime high-water rules. It is compiled together with the
model rather than run standalone:

```sh
swiftc openflow/Models/HomeActivityStats.swift \
  scripts/check-home-activity-stats.swift -o /tmp/openflow-home-activity-check
/tmp/openflow-home-activity-check
```

`scripts/ci-linux.sh` does exactly that (plus `scripts/check-history-privacy.swift`
for the lifetime-versus-history rules) whenever `swift` is available.
