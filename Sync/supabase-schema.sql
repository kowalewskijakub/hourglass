-- Hourglass — Supabase sync schema, v2.
--
-- IDEMPOTENT AND CUMULATIVE: paste the whole file into the Supabase SQL editor
-- and run it — on a brand-new project or over any previous Hourglass schema —
-- and it converges to the current shape. Every statement either guards itself
-- (`if not exists`, `drop … if exists`, exception blocks) or is a no-op on
-- re-run. The `schema_version` table at the bottom is how clients verify the
-- database speaks their protocol before writing to it.
--
-- v2 highlights:
--   * work_breaks: breaks are rows of their own (per-break merge, not
--     whole-day last-writer-wins). Existing embedded JSON breaks migrate.
--   * ignore_stale_writes trigger: the server itself refuses to let an older
--     `updated_at` overwrite a newer row, whatever order writes arrive in.
--   * live_state.session_id: the running session's identity, so every device
--     records its completion under the same id.
--   * Pairing no longer stores refresh tokens: a code now buys the joining
--     device a login link of its own via the `claim-pairing` Edge Function
--     (see supabase/functions/claim-pairing).

-- ---------------------------------------------------------------------------
-- 1) Tables
-- ---------------------------------------------------------------------------

-- live_state: exactly one row per user = the currently running / paused timer.
-- The countdown is NOT streamed; devices compute it locally from end_date.
create table if not exists public.live_state (
    user_id        uuid primary key references auth.users (id) on delete cascade,
    kind           text        not null,          -- focus | shortBreak | longBreak
    end_date       timestamptz,                    -- when the running session ends
    is_running     boolean     not null default false,
    paused_at      timestamptz,                    -- frozen instant while paused
    cycle_position int         not null default 0,
    session_id     uuid,                           -- identity of the session on the clock
    origin_device  text        not null,           -- to filter out our own echoes
    updated_at     timestamptz not null default now()
);
alter table public.live_state add column if not exists session_id uuid;

-- sessions: recorded history (append + edit by id).
create table if not exists public.sessions (
    id               uuid              not null,
    user_id          uuid              not null references auth.users (id) on delete cascade,
    kind             text              not null,
    planned_duration double precision  not null,   -- seconds
    started_at       timestamptz       not null,
    ended_at         timestamptz,
    completed        boolean           not null default true,
    updated_at       timestamptz       not null default now(),
    deleted_at       timestamptz,                  -- tombstone; null = live row
    primary key (user_id, id)
);
alter table public.sessions add column if not exists deleted_at timestamptz;
create index if not exists sessions_user_started_idx
    on public.sessions (user_id, started_at desc);

-- settings: one row per user (TimerSettings as JSON).
create table if not exists public.settings (
    user_id    uuid primary key references auth.users (id) on delete cascade,
    payload    jsonb       not null,
    updated_at timestamptz not null default now()
);

-- clock_sessions: clocked-in stretches of a working day. Breaks live in
-- work_breaks below; a legacy `breaks` jsonb column may linger on projects
-- created before v2 (its contents are migrated below, then it is ignored).
create table if not exists public.clock_sessions (
    id             uuid        not null,
    user_id        uuid        not null references auth.users (id) on delete cascade,
    clocked_in_at  timestamptz not null,
    clocked_out_at timestamptz,
    updated_at     timestamptz not null default now(),
    deleted_at     timestamptz,                    -- tombstone; null = live row
    primary key (user_id, id)
);
alter table public.clock_sessions add column if not exists deleted_at timestamptz;
create index if not exists clock_sessions_user_start_idx
    on public.clock_sessions (user_id, clocked_in_at desc);

-- work_breaks: one row per break, keyed to its clock session. Two devices
-- editing different breaks of the same day now merge; under the old embedded
-- array, whichever device wrote the session row last erased the other's.
create table if not exists public.work_breaks (
    id               uuid        not null,
    user_id          uuid        not null references auth.users (id) on delete cascade,
    clock_session_id uuid        not null,
    started_at       timestamptz not null,
    ended_at         timestamptz,
    updated_at       timestamptz not null default now(),
    deleted_at       timestamptz,                  -- tombstone; null = live row
    primary key (user_id, id)
);
create index if not exists work_breaks_user_session_idx
    on public.work_breaks (user_id, clock_session_id);

-- ---------------------------------------------------------------------------
-- 2) Older projects: move the primary keys to (user_id, id)
-- Session and clock ids are generated on-device and shared across devices, so
-- two accounts can hold the same id. With `id` alone as the key, one account's
-- row blocks the other's write: the upsert becomes an UPDATE and RLS refuses
-- it. (Fresh tables above are already keyed this way.)
-- ---------------------------------------------------------------------------
do $$
begin
    if exists (
        select 1 from pg_constraint
        where conrelid = 'public.sessions'::regclass
          and contype = 'p' and array_length(conkey, 1) = 1
    ) then
        alter table public.sessions drop constraint sessions_pkey;
        alter table public.sessions add primary key (user_id, id);
    end if;
    if exists (
        select 1 from pg_constraint
        where conrelid = 'public.clock_sessions'::regclass
          and contype = 'p' and array_length(conkey, 1) = 1
    ) then
        alter table public.clock_sessions drop constraint clock_sessions_pkey;
        alter table public.clock_sessions add primary key (user_id, id);
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3) Older projects: migrate embedded breaks JSON into work_breaks
-- The JSON was written by the Swift SDK: zoneless ISO-8601 strings in UTC,
-- camelCase keys. Parent updated_at stands in for the per-break stamp the old
-- format never had. Already-migrated rows are left alone.
-- ---------------------------------------------------------------------------
do $$
begin
    if exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'clock_sessions'
          and column_name = 'breaks'
    ) then
        insert into public.work_breaks (id, user_id, clock_session_id, started_at, ended_at, updated_at)
        select
            (b->>'id')::uuid,
            cs.user_id,
            cs.id,
            ((b->>'startedAt')::timestamp at time zone 'utc'),
            case when (b->>'endedAt') is not null
                 then ((b->>'endedAt')::timestamp at time zone 'utc')
            end,
            cs.updated_at
        from public.clock_sessions cs
        cross join lateral jsonb_array_elements(coalesce(cs.breaks, '[]'::jsonb)) as b
        where b ? 'id'
        on conflict (user_id, id) do nothing;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4) The server-side staleness guard
-- Last-writer-wins is only trustworthy if it holds on the server too. Clients
-- drain writes through an ordered queue, but reordering can still happen
-- (retries, two devices racing) — so a BEFORE UPDATE trigger simply ignores
-- any write stamped older than the row it would replace. The upsert still
-- reports success; the newer row stands.
-- ---------------------------------------------------------------------------
create or replace function public.ignore_stale_writes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.updated_at < old.updated_at then
        return null; -- skip the update, keep the newer row
    end if;
    return new;
end;
$$;

-- live_state gets one extra rule: an exact stamp tie (two devices writing the
-- same millisecond) resolves by origin_device — the SAME tie-break the clients
-- apply — so server and every device agree on the winner instead of the
-- server keeping whichever write happened to commit last.
create or replace function public.ignore_stale_live_writes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.updated_at < old.updated_at
       or (new.updated_at = old.updated_at and new.origin_device < old.origin_device) then
        return null;
    end if;
    return new;
end;
$$;

drop trigger if exists ignore_stale_writes on public.live_state;
create trigger ignore_stale_writes before update on public.live_state
    for each row execute function public.ignore_stale_live_writes();
drop trigger if exists ignore_stale_writes on public.sessions;
create trigger ignore_stale_writes before update on public.sessions
    for each row execute function public.ignore_stale_writes();
drop trigger if exists ignore_stale_writes on public.clock_sessions;
create trigger ignore_stale_writes before update on public.clock_sessions
    for each row execute function public.ignore_stale_writes();
drop trigger if exists ignore_stale_writes on public.work_breaks;
create trigger ignore_stale_writes before update on public.work_breaks
    for each row execute function public.ignore_stale_writes();
drop trigger if exists ignore_stale_writes on public.settings;
create trigger ignore_stale_writes before update on public.settings
    for each row execute function public.ignore_stale_writes();

-- ---------------------------------------------------------------------------
-- 5) Row-level security: every user touches only their own rows
-- ---------------------------------------------------------------------------
alter table public.live_state     enable row level security;
alter table public.sessions       enable row level security;
alter table public.settings       enable row level security;
alter table public.clock_sessions enable row level security;
alter table public.work_breaks    enable row level security;

drop policy if exists "own live_state" on public.live_state;
create policy "own live_state" on public.live_state
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "own sessions" on public.sessions;
create policy "own sessions" on public.sessions
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "own settings" on public.settings;
create policy "own settings" on public.settings
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "own clock_sessions" on public.clock_sessions;
create policy "own clock_sessions" on public.clock_sessions
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "own work_breaks" on public.work_breaks;
create policy "own work_breaks" on public.work_breaks
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 6) Realtime: broadcast row changes over WebSocket to subscribed clients
-- ---------------------------------------------------------------------------
do $$ begin
    alter publication supabase_realtime add table public.live_state;
exception when duplicate_object then null; end $$;
do $$ begin
    alter publication supabase_realtime add table public.sessions;
exception when duplicate_object then null; end $$;
do $$ begin
    alter publication supabase_realtime add table public.settings;
exception when duplicate_object then null; end $$;
do $$ begin
    alter publication supabase_realtime add table public.clock_sessions;
exception when duplicate_object then null; end $$;
do $$ begin
    alter publication supabase_realtime add table public.work_breaks;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 7) Device pairing, v2 — no refresh tokens anywhere
--
-- Sync uses an anonymous account: the first device creates one, any other
-- device joins it with a short-lived, single-use code. v1 stored the first
-- device's refresh token and handed it to the joiner — but refresh tokens
-- rotate on use, so the two devices shared one token family and the server's
-- reuse detection signed them BOTH out within the hour. v2 stores only the
-- account id; the `claim-pairing` Edge Function (service role) exchanges a
-- valid code for a fresh one-time login link, so each device gets a session
-- of its own.
--
-- The table is locked down twice over: RLS on with no policies, and grants
-- revoked from anon/authenticated. Codes are stored as SHA-256 hashes.
--
-- Requires "Enable anonymous sign-ins" in Authentication -> Sign In / Providers,
-- and the Edge Function deployed:  supabase functions deploy claim-pairing
-- ---------------------------------------------------------------------------
create table if not exists public.device_pairings (
    code_hash  text primary key,
    user_id    uuid not null references auth.users (id) on delete cascade,
    expires_at timestamptz not null
);
alter table public.device_pairings drop column if exists refresh_token;

alter table public.device_pairings enable row level security;
revoke all on table public.device_pairings from anon, authenticated;

-- v1 functions, replaced wholesale.
drop function if exists public.create_pairing(text, text);
drop function if exists public.claim_pairing(text);

-- Device A publishes its account id under a hashed code.
create or replace function public.create_pairing(p_code text)
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

    insert into public.device_pairings (code_hash, user_id, expires_at)
    values (
        encode(sha256(p_code::bytea), 'hex'),
        auth.uid(),
        now() + interval '5 minutes'
    )
    -- Refresh our own code freely, but never rebind someone else's: without
    -- the guard, anyone who glimpsed an active code could re-publish it under
    -- their account and the joining device would pair to the eavesdropper.
    on conflict (code_hash) do update
        set expires_at = excluded.expires_at
        where device_pairings.user_id = excluded.user_id;
end;
$$;

-- The Edge Function (and only it) redeems a code for the account id. Returns
-- null for a wrong, used or expired code alike, so codes can't be enumerated.
create or replace function public.claim_pairing_code(p_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_hash text := encode(sha256(p_code::bytea), 'hex');
    v_user uuid;
begin
    delete from public.device_pairings where expires_at < now();

    delete from public.device_pairings
     where code_hash = v_hash
       and expires_at >= now()
    returning user_id into v_user;

    return v_user;
end;
$$;

revoke all on function public.create_pairing(text) from public, anon;
grant execute on function public.create_pairing(text) to authenticated;
-- claim_pairing_code is for the service role only — devices go through the
-- Edge Function, which rate-limits and mints the login link.
revoke all on function public.claim_pairing_code(text) from public, anon, authenticated;
grant execute on function public.claim_pairing_code(text) to service_role;

-- ---------------------------------------------------------------------------
-- 8) Schema version — how clients know this file has been run
-- Clients require a minimum version at connect and refuse to sync against an
-- older database (writing v2 rows into a v1 schema fails in confusing ways).
-- Bump the inserted version whenever the protocol changes shape.
-- ---------------------------------------------------------------------------
create table if not exists public.schema_version (
    version    int primary key,
    applied_at timestamptz not null default now()
);
alter table public.schema_version enable row level security;
drop policy if exists "read schema version" on public.schema_version;
create policy "read schema version" on public.schema_version
    for select to authenticated using (true);

insert into public.schema_version (version) values (2)
on conflict (version) do nothing;
