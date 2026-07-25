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
