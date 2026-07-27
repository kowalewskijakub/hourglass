-- Hourglass — Supabase sync schema
-- Paste this into the Supabase SQL editor (Project → SQL → New query → Run).

-- 1) live_state: exactly one row per user = the currently running / paused timer.
--    The countdown is NOT streamed; devices compute it locally from end_date.
create table if not exists public.live_state (
    user_id        uuid primary key references auth.users (id) on delete cascade,
    kind           text        not null,          -- focus | shortBreak | longBreak
    end_date       timestamptz,                    -- when the running session ends
    is_running     boolean     not null default false,
    paused_at      timestamptz,                    -- frozen instant while paused
    cycle_position int         not null default 0,
    origin_device  text        not null,           -- to filter out our own echoes
    updated_at     timestamptz not null default now()
);

-- 2) sessions: recorded history (append + edit by id).
create table if not exists public.sessions (
    id               uuid primary key,
    user_id          uuid              not null references auth.users (id) on delete cascade,
    kind             text              not null,
    planned_duration double precision  not null,   -- seconds
    started_at       timestamptz       not null,
    ended_at         timestamptz,
    completed        boolean           not null default true,
    updated_at       timestamptz       not null default now()
);
create index if not exists sessions_user_started_idx
    on public.sessions (user_id, started_at desc);

-- 3) settings: one row per user (TimerSettings as JSON).
create table if not exists public.settings (
    user_id    uuid primary key references auth.users (id) on delete cascade,
    payload    jsonb       not null,
    updated_at timestamptz not null default now()
);

-- Row-level security: every user can only touch their own rows.
alter table public.live_state enable row level security;
alter table public.sessions   enable row level security;
alter table public.settings   enable row level security;

create policy "own live_state" on public.live_state
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own sessions" on public.sessions
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own settings" on public.settings
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Realtime: broadcast row changes over WebSocket to subscribed clients.
alter publication supabase_realtime add table public.live_state;
alter publication supabase_realtime add table public.sessions;
alter publication supabase_realtime add table public.settings;

-- ---------------------------------------------------------------------------
-- Device pairing (applied 2026-07-26)
--
-- Sync uses an anonymous account: the first device creates one, and any other
-- device joins it by redeeming a short-lived, single-use code. The code is
-- exchanged for the account's refresh token.
--
-- The table holds refresh tokens, so it is locked down twice over: RLS is on
-- with NO policies, and the table grants are revoked from anon/authenticated.
-- The only way in is the SECURITY DEFINER functions below. Codes are stored as
-- SHA-256 hashes, so an active code is never readable at rest.
--
-- Requires "Enable anonymous sign-ins" in Authentication -> Sign In / Providers.
-- ---------------------------------------------------------------------------
create table if not exists public.device_pairings (
    code_hash     text primary key,
    user_id       uuid not null references auth.users (id) on delete cascade,
    refresh_token text not null,
    expires_at    timestamptz not null
);

alter table public.device_pairings enable row level security;
revoke all on table public.device_pairings from anon, authenticated;

-- Device A publishes its refresh token under a hashed code.
create or replace function public.create_pairing(p_code text, p_refresh_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'must be signed in to create a pairing';
    end if;

    delete from public.device_pairings where expires_at < now();

    insert into public.device_pairings (code_hash, user_id, refresh_token, expires_at)
    values (
        encode(sha256(p_code::bytea), 'hex'),
        auth.uid(),
        p_refresh_token,
        now() + interval '5 minutes'
    )
    on conflict (code_hash) do update
        set user_id       = excluded.user_id,
            refresh_token = excluded.refresh_token,
            expires_at    = excluded.expires_at;
end;
$$;

-- Device B redeems the code exactly once, before it expires. Returns null for a
-- wrong, used or expired code alike, so codes can't be enumerated.
create or replace function public.claim_pairing(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_hash  text := encode(sha256(p_code::bytea), 'hex');
    v_token text;
begin
    delete from public.device_pairings where expires_at < now();

    delete from public.device_pairings
     where code_hash = v_hash
       and expires_at >= now()
    returning refresh_token into v_token;

    return v_token;
end;
$$;

revoke all on function public.create_pairing(text, text) from public, anon;
revoke all on function public.claim_pairing(text) from public;
grant execute on function public.create_pairing(text, text) to authenticated;
-- anon needs this: the joining device has no session yet.
grant execute on function public.claim_pairing(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Clock sessions (applied 2026-07-26)
-- Clocked-in stretches of a working day. Breaks travel as JSONB because they
-- only ever move with their parent session.
-- ---------------------------------------------------------------------------
create table if not exists public.clock_sessions (
    id             uuid primary key,
    user_id        uuid        not null references auth.users (id) on delete cascade,
    clocked_in_at  timestamptz not null,
    clocked_out_at timestamptz,
    breaks         jsonb       not null default '[]'::jsonb,
    updated_at     timestamptz not null default now()
);

create index if not exists clock_sessions_user_start_idx
    on public.clock_sessions (user_id, clocked_in_at desc);

alter table public.clock_sessions enable row level security;

create policy "own clock_sessions" on public.clock_sessions
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

alter publication supabase_realtime add table public.clock_sessions;

-- ---------------------------------------------------------------------------
-- Per-user row keys (applied 2026-07-27)
-- Session and clock ids are generated on-device and shared across devices, so
-- two accounts can hold the same id. With `id` alone as the primary key, one
-- account's row blocks the other's write: the upsert becomes an UPDATE and RLS
-- refuses it. Keying by (user_id, id) gives each account its own copy.
-- Clients must upsert with on_conflict=user_id,id.
-- ---------------------------------------------------------------------------
alter table public.sessions drop constraint if exists sessions_pkey;
alter table public.sessions add primary key (user_id, id);

alter table public.clock_sessions drop constraint if exists clock_sessions_pkey;
alter table public.clock_sessions add primary key (user_id, id);

-- ---------------------------------------------------------------------------
-- Tombstones (applied 2026-07-27)
-- A row that is simply DELETEd leaves the other devices no way to learn it is
-- gone. Realtime reports a delete as a bare primary key with no row behind it,
-- and a device that was asleep or offline at the time is told nothing at all —
-- it still holds its copy, and uploads it again on the next connect, which is
-- how a deleted session comes back.
--
-- Keeping the row and stamping `deleted_at` turns a deletion into an ordinary
-- update: Realtime carries it, a reconnecting device reads it in the initial
-- fetch, and both can weigh it against their own copy by `updated_at` exactly
-- like any other change.
--
-- Nullable, so every row that already exists reads as "not deleted".
-- ---------------------------------------------------------------------------
alter table public.sessions       add column if not exists deleted_at timestamptz;
alter table public.clock_sessions add column if not exists deleted_at timestamptz;
