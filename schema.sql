-- ============================================================
-- FanPair — Supabase Schema  (drop & recreate cleanly)
-- Run this in: Dashboard → SQL Editor → New query → Run
-- ============================================================

-- 0. CLEAN SLATE (safe to re-run)

drop table if exists messages cascade;
drop table if exists rooms    cascade;
drop table if exists queue    cascade;
drop table if exists matches  cascade;
drop function if exists pair_users(text, text, uuid);

-- 1. TABLES

create table matches (
  id          uuid primary key default gen_random_uuid(),
  external_id text unique,
  home_team   text not null,
  away_team   text not null,
  home_flag   text default '',
  away_flag   text default '',
  status      text default 'upcoming',
  kickoff_at  timestamptz not null default now(),
  home_score  int default 0,
  away_score  int default 0,
  stage       text default 'FIFA World Cup 2026',
  minute      int default 0
);

create table queue (
  id          uuid primary key default gen_random_uuid(),
  session_id  text not null,
  match_id    uuid references matches(id) on delete cascade,
  preference  text default 'any',
  paired      boolean default false,
  created_at  timestamptz default now()
);

create table rooms (
  id              uuid primary key default gen_random_uuid(),
  match_id        uuid references matches(id),
  session_a       text not null,
  session_b       text not null,
  created_at      timestamptz default now(),
  expires_at      timestamptz not null,
  extend_vote_a   boolean default false,
  extend_vote_b   boolean default false
);

create table messages (
  id          uuid primary key default gen_random_uuid(),
  room_id     uuid references rooms(id) on delete cascade,
  session_id  text not null,
  content     text not null,
  created_at  timestamptz default now()
);

-- 2. GRANTS  (anon = what your publishable key maps to)

grant usage on schema public to anon;

grant select, insert, update on matches  to anon;
grant select, insert, update, delete on queue    to anon;
grant select, insert, update on rooms    to anon;
grant select, insert         on messages to anon;

-- 3. ROW LEVEL SECURITY

alter table matches  enable row level security;
alter table queue    enable row level security;
alter table rooms    enable row level security;
alter table messages enable row level security;

create policy "anon all matches"  on matches  for all to anon using (true) with check (true);
create policy "anon all queue"    on queue    for all to anon using (true) with check (true);
create policy "anon all rooms"    on rooms    for all to anon using (true) with check (true);
create policy "anon all messages" on messages for all to anon using (true) with check (true);

-- 4. REALTIME

do $$ begin
  begin alter publication supabase_realtime add table messages;
  exception when others then null; end;
  begin alter publication supabase_realtime add table rooms;
  exception when others then null; end;
end $$;

-- 5. PAIRING FUNCTION

create function pair_users(
  my_session    text,
  their_session text,
  p_match_id    uuid
)
returns uuid
language plpgsql
security definer
as $$
declare
  new_room_id    uuid;
  my_queue_id    uuid;
  their_queue_id uuid;
begin
  select id into my_queue_id
    from queue
    where session_id = my_session and paired = false
    for update skip locked;

  if my_queue_id is null then return null; end if;

  select id into their_queue_id
    from queue
    where session_id = their_session and paired = false
    for update skip locked;

  if their_queue_id is null then return null; end if;

  update queue set paired = true
    where id in (my_queue_id, their_queue_id);

  insert into rooms (match_id, session_a, session_b, expires_at)
    values (p_match_id, my_session, their_session, now() + interval '22 minutes 30 seconds')
    returning id into new_room_id;

  return new_room_id;
end;
$$;

grant execute on function pair_users(text, text, uuid) to anon;
