# Real-time sync (Supabase + Sign in with Apple)

Live timer + settings + history sync across macOS and iOS. No iCloud. The running
session mirrors in ~1s because devices exchange only `{kind, end_date, is_running,
paused_at}` and compute the countdown locally from `end_date`.

## Prerequisites (you provide)

### 1. Supabase project
- Create a free project at https://supabase.com.
- Run [`supabase-schema.sql`](supabase-schema.sql) in the SQL editor.
- Copy the **Project URL** and **anon public** key (Project Settings → API). The
  anon key is safe to embed in a client app (RLS protects the data).

### 2. Sign in with Apple  ⚠️ needs a paid Apple Developer account
"Sign in with Apple" is an **entitlement**, so both apps must be signed with a real
**Development Team** (Apple Developer Program, $99/yr) — the current ad-hoc
`CODE_SIGN_IDENTITY = "-"` cannot carry it. You'll need to:
- Enable the **Sign in with Apple** capability on both App IDs
  (`com.hourglass.mac`, `com.hourglass.ios`) in the Apple Developer portal.
- Set `DEVELOPMENT_TEAM` in `project.yml` and switch signing to Automatic.
- In Supabase → Authentication → Providers → **Apple**, add both bundle IDs as
  authorized client IDs (for native token sign-in no client secret is required).

> No Apple Developer account? The cleanest fallback with ad-hoc signing is
> **email magic link** — say the word and I'll wire that instead (no entitlement,
> no team needed).

### 3. Credentials
Add `Sync/SyncConfig.swift` (git-ignored) — I'll provide the template:
```swift
enum SyncConfig {
    static let supabaseURL = URL(string: "https://YOUR-PROJECT.supabase.co")!
    static let supabaseAnonKey = "YOUR-ANON-KEY"
}
```

## What I'll build once the above is ready
- Add the `supabase-swift` SPM package to both app targets.
- A `SyncService` (@MainActor): sign-in, initial load, Realtime subscriptions,
  push local changes (hooked into the engine callbacks + stores), apply remote.
- Live mirroring via an upsert to `live_state` on every start/pause/resume/scrub/
  complete; echo filtered by `origin_device`; last-writer-wins.
- A **Sync** section in Settings (sign in/out, on/off, status).

## The protocol

### The running timer (`live_state`)
One row per user, upserted on every engine transition, echo filtered by
`origin_device`. The countdown is never streamed — the receiving device
reconstructs it:

| state   | `end_date`            | `paused_at` | `is_running` |
|---------|-----------------------|-------------|--------------|
| running | now + remaining       | null        | true         |
| paused  | `paused_at` + remaining | frozen instant | false     |
| idle    | null                  | null        | false        |

A pause is **not** the absence of a run: both report `is_running = false`, so
what distinguishes them is `paused_at`. What is left to run is
`end_date - paused_at`, which is why a paused row can sit on the server for an
hour and still resume where it froze. All three shapes are written explicitly —
a nil that is merely omitted would leave the previous value standing, because an
upsert only touches the columns its payload names.

**Who records the session.** Both devices reconstruct the countdown, so both
reach zero — but the Pomodoro happened once. The device that *started* it owns
the history row; the other is mirroring and writes nothing, locally or upstream,
or the same session lands twice under two ids. It is still told the session
finished, so the person watching that screen still gets the alert.

Adopting a remote timer never takes ownership away from a session started on
this device: only an idle device — or one already mirroring — becomes a mirror.
That is the tie-break for two devices auto-starting the same phase at the same
instant; without it each would disown the session and it would be recorded
nowhere, which is worse than the duplicate it replaces.

### History and workdays (`sessions`, `clock_sessions`)
Last writer wins, decided by `updated_at`, which the client stamps on every write
(the column default only fires on insert). A row with no stamp — written before
they existed — counts as the oldest thing there is.

Deletions are **soft**: the row stays and `deleted_at` is stamped. A hard DELETE
is invisible to the other devices (Realtime reports it as a bare key with no row
behind it, and a device that was offline is told nothing at all), so the deleted
row simply came back the next time a device that still held it connected.
Applying a row with `deleted_at` set deletes it locally.

Every other column is written explicitly, for the same reason `live_state` is: an
upsert only touches the columns its payload names, so an omitted nil would leave
the old value standing. Reopening a workday (clearing `clocked_out_at`) used to
be undone by its own echo. `deleted_at` is the sole exception — it is named only
on a tombstone, so a live row still writes to a database that predates it.

A tombstone's remaining columns are placeholders, chosen to be **inert**: a
zero-length, already-closed record. A device on a build that predates tombstones
ignores `deleted_at` and reads the row as ordinary, so it must not describe a
workday that is still open.

Deletion is the one change that erases its own evidence — the push walks what the
device still holds, and a deleted row is not among it. So a deletion is recorded
locally before it is sent, replayed on the next connect if it never landed, and
forgotten only once the server confirms it. A replay carries the original
deletion instant, never the retry time, so it cannot outrank a genuine later edit
from another device.

### Settings
Also last-writer-wins, but `TimerSettings` carries no stamp, so the device keeps
its own record of when it last changed them. Only a device that changed settings
later than the server's copy uploads. Holding a *different* copy is not evidence
of holding a **newer** one: without that record, a device that had changed
nothing for a week overwrote the change another device made yesterday, and
neither side showed a trace of it.

### Connecting
Push, then pull, then subscribe. Push first because anything changed while
signed out was never sent, and pulling first would overwrite it. But the push
**reconciles** rather than re-uploading everything: it reads the server's
`updated_at` per row and sends only what the server has never seen or what this
device changed later. Still holding a row is not evidence it should exist — that
is exactly how a stale device buries another device's tombstone.

> ⚠️ Deleting anything writes to `sessions.deleted_at` / `clock_sessions.deleted_at`.
> If your project predates that column, re-run [`supabase-schema.sql`](supabase-schema.sql)
> (it is `add column if not exists`, so re-running the whole file is safe) or the
> write is rejected and the deletion never leaves the device.
