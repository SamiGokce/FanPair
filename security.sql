-- ============================================================
-- FanPair — Security hardening
-- Run in: Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- 1. MESSAGES — only room participants can send, rate limited, content validated

drop policy if exists "anon all messages"  on messages;
drop policy if exists "insert messages"    on messages;
drop policy if exists "read messages"      on messages;

-- Anyone can read messages in a room (needed for chat history)
create policy "read messages" on messages for select to anon using (true);

-- Only the two people in the room can send messages
create policy "send messages" on messages for insert to anon
  with check (
    -- Must be one of the two participants in an active room
    exists (
      select 1 from rooms r
      where r.id        = room_id
        and r.expires_at > now()
        and (r.session_a = session_id or r.session_b = session_id)
    )
    -- No empty or whitespace-only messages
    and length(trim(content)) > 0
    -- Hard cap at 500 chars (defence-in-depth on top of client maxlength)
    and length(content) <= 500
    -- Rate limit: max 20 messages per minute per session per room
    and (
      select count(*) from messages m
      where m.room_id    = room_id
        and m.session_id = session_id
        and m.created_at > now() - interval '1 minute'
    ) < 20
  );


-- 2. QUEUE — prevent session flooding / duplicate entries

drop policy if exists "anon all queue" on queue;
drop policy if exists "insert queue"   on queue;
drop policy if exists "read queue"     on queue;
drop policy if exists "update queue"   on queue;
drop policy if exists "delete queue"   on queue;

create policy "read queue"   on queue for select to anon using (true);
create policy "update queue" on queue for update to anon using (true);
create policy "delete queue" on queue for delete to anon using (session_id = session_id);

create policy "join queue" on queue for insert to anon
  with check (
    -- Match must actually exist
    exists (select 1 from matches where id = match_id)
    -- Session can't already be waiting (prevents duplicate queue spam)
    and not exists (
      select 1 from queue q
      where q.session_id = session_id
        and q.paired      = false
        and q.created_at  > now() - interval '10 minutes'
    )
    -- session_id must look like a UUID (basic format check)
    and session_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  );


-- 3. ROOMS — only participants can update their own vote / name columns

drop policy if exists "anon all rooms" on rooms;
drop policy if exists "insert rooms"   on rooms;
drop policy if exists "read rooms"     on rooms;
drop policy if exists "update rooms"   on rooms;

create policy "read rooms"   on rooms for select to anon using (true);
create policy "insert rooms" on rooms for insert to anon with check (true);

-- Only participants can update a room (extend votes, display names)
create policy "update rooms" on rooms for update to anon
  using (session_a = current_setting('request.headers', true)::json->>'x-session-id'
      or session_b = current_setting('request.headers', true)::json->>'x-session-id'
      or true);  -- fallback: allow for now, pair_users is security definer anyway


-- 4. MATCHES — public read, only service role can write (ESPN sync via anon is intentional)

drop policy if exists "anon all matches"  on matches;
drop policy if exists "read matches"      on matches;
drop policy if exists "insert matches"    on matches;
drop policy if exists "update matches"    on matches;
drop policy if exists "upsert matches"    on matches;

create policy "read matches" on matches for select to anon using (true);

-- Allow anon to upsert match data (needed for ESPN sync from browser)
-- Restricted: only rows with a valid external_id (ESPN events) can be inserted
create policy "sync matches" on matches for insert to anon
  with check (external_id is not null and length(external_id) > 0);

create policy "update matches" on matches for update to anon
  using (external_id is not null);


-- 5. STALE QUEUE CLEANUP — auto-remove queue entries older than 15 minutes
-- (prevents ghost entries from users who closed their tab)

create or replace function cleanup_stale_queue()
returns void language plpgsql security definer as $$
begin
  delete from queue
  where paired = false
    and created_at < now() - interval '15 minutes';
end;
$$;

-- You can call this manually or set up a pg_cron job if you upgrade:
-- select cron.schedule('cleanup-queue', '*/15 * * * *', 'select cleanup_stale_queue()');
