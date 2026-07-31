# Real-time sync (Supabase, protocol v2)

Live timer + workdays + history + settings sync across macOS and iOS. No
iCloud. The running session mirrors in ~1s because devices exchange only a tiny
`live_state` row and compute the countdown locally from `end_date`.

## Setup

1. Create a free project at https://supabase.com.
2. Run [`supabase-schema.sql`](supabase-schema.sql) in the SQL editor. The file
   is **idempotent and cumulative**: safe to run on a fresh project or over any
   older Hourglass schema, and re-running it is the upgrade path. Clients check
   the `schema_version` table at connect and pause with an actionable message
   if the database is older than they are.
3. Deploy the pairing Edge Function from the repo root:
   `supabase functions deploy claim-pairing`
   (source in [`supabase/functions/claim-pairing`](../supabase/functions/claim-pairing/index.ts);
   `supabase/config.toml` disables gateway JWT verification for it — required,
   because the joining device is signed out when it calls. If deploying some
   other way, pass `--no-verify-jwt`.)
4. Enable **anonymous sign-ins**: Authentication → Sign In / Providers.
5. Add `Sync/SyncConfig.swift` (git-ignored) with the project URL and anon key.

> ⚠️ **Update every device together.** A pre-v2 build doesn't check the schema
> version and writes the old shapes (no `session_id`, embedded breaks). Mixed
> fleets mostly degrade gracefully, but a v1 write can leave a stale
> `live_state.session_id` standing for v2 peers. In practice v1 builds can't
> hold a session for more than an hour anyway (the token-sharing bug below),
> so updating everything at once is both required and painless.

## The five guarantees, and what enforces them

1. **No write is lost or reordered.** Every outgoing write — rows, settings,
   the live timer, deletions — goes through `SyncOutbox`: a durable, ordered,
   coalescing queue on disk, drained front-to-back by a single worker with
   backoff retry. An entry leaves the queue only when the server confirms it.
   Offline just means the queue grows; reconnecting drains it before anything
   is pulled.
2. **Conflicts resolve the same way everywhere, even with skewed clocks.**
   Last-writer-wins on `updated_at`, stamped by `HybridStampClock`: stamps
   never repeat and never fall behind a stamp already seen from the server, so
   a device with a fast wall clock cannot bury an edit made after its write
   was seen. The same rule is enforced twice: at apply time on every client,
   and by the `ignore_stale_writes` trigger on the server — whatever order
   writes arrive in, the newer row stands.
3. **A deletion is a fact, not an absence.** Deletes are tombstone rows
   (`deleted_at`), compared by stamp like any other change; live rows write
   `deleted_at = null` explicitly, so an edit that outranks a tombstone
   *resurrects* the row instead of half-dying under it. Tombstones ride the
   same outbox as everything else, so an offline deletion replays with its
   original stamp.
4. **One Pomodoro, one record.** The live state carries the running session's
   id. Every device that witnesses the finish records it under that id and the
   stores upsert by id, so however many devices were watching — or auto-started
   the next phase together — history holds one row. The engine announces a
   completion only *after* advancing to the next phase, so the row peers adopt
   is the settled state, never "running, ends right now, old position".
5. **Breaks merge, they don't clobber.** Each break is its own `work_breaks`
   row with its own stamp. Two devices editing different parts of the same day
   merge cleanly; the old embedded-array design let a stale offline device
   erase a whole day's breaks with one late clock-out.

## The running timer (`live_state`)

One row per user, upserted on every engine transition, echo-filtered by
`origin_device`, and applied only above the device's *floor* — the newest
stamp it has pushed or applied (exact ties break on the device id, so exactly
one of two racing devices yields and session ids converge). The countdown is
never streamed; the receiver reconstructs it:

| state   | `end_date`              | `paused_at`    | `is_running` |
|---------|-------------------------|----------------|--------------|
| running | now + remaining         | null           | true         |
| paused  | `paused_at` + remaining | frozen instant | false        |
| idle    | null                    | null           | false        |

Adopting a remote timer fires no engine callbacks (it is a mirror of a
decision made elsewhere) but returns what changed, and the app forwards that
to the host hooks — so a mirrored Pomodoro still schedules its completion
notification and Live Activity.

An idle device never volunteers its live state at connect: after a day
offline its confidently-stamped "idle" would kill a session running elsewhere.
A non-idle timer is a live user intention and is pushed.

## Connecting, reconnecting, refreshing

`connect = check schema version → drain outbox → reconcile → subscribe → pull`.

The reconcile covers what predates the outbox or happened while sync was off:
it reads the server's `id/updated_at` pairs and uploads only what the server
has never seen or what this device changed strictly later — still holding a
row is not evidence it should exist; that is exactly how a stale device buries
a tombstone.

Realtime is watched, not trusted: every channel recovery to `subscribed`
drains and re-pulls (events during the gap are gone for good otherwise), and
the foreground/wake `refresh()` does the same. Pulls apply through the same
staleness guards as realtime events, so pulling is always safe.

## Pairing (v2 — no shared refresh tokens)

The first device signs in anonymously. "Pair another device" publishes an
8-character single-use code (5-minute expiry, stored hashed, account id only).
The joining device sends the code to the `claim-pairing` Edge Function, which
consumes it atomically and uses the service role to mint a **one-time login
link** for the account; the device verifies the returned token hash and holds
a session of its own.

v1 handed the joiner the first device's refresh token. Refresh tokens rotate
on use, so both devices shared one token family and GoTrue's reuse detection
signed them **both** out within about an hour of pairing — the single biggest
"sync randomly breaks" in the alpha.

Auth state is observed: if the session dies, the UI says so (`sessionLost`)
and offers re-pairing. It never silently creates a fresh anonymous account —
that would strand the data and split the user's devices across two accounts,
each showing a green "Syncing".

"Turn off sync" **pauses** (keeps the session; anonymous accounts have no
other key). Disconnecting for good is a separate, confirmed, destructive
action.

## Testing

`Packages/HourglassCore` holds the protocol: wire rows, outbox, stamp clock,
merge rules, engine, tracker. `SyncSimulationTests.swift` runs multi-device
simulations against a fake server that enforces the same trigger the schema
installs — deterministic regressions for every defect the 2026-07 sync audit
confirmed, plus a seeded randomized sweep asserting the core property: any
interleaving of actions, offline stretches and reconnects converges to
identical data on every device once quiescent. `SyncService` itself stays a
thin transport adapter.
