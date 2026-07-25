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
