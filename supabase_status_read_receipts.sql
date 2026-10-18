-- ZouChat: statuts 24 h et confirmations de lecture.
-- À exécuter une seule fois dans Supabase > SQL Editor.
create table if not exists public.zouchat_statuses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  content text not null check (char_length(content) between 1 and 500),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours')
);
create index if not exists zouchat_statuses_expiry_idx on public.zouchat_statuses(expires_at desc);
alter table public.zouchat_statuses enable row level security;
drop policy if exists "Authenticated users can read active statuses" on public.zouchat_statuses;
create policy "Authenticated users can read active statuses" on public.zouchat_statuses
 for select to authenticated using (expires_at > now());
drop policy if exists "Users can publish own statuses" on public.zouchat_statuses;
create policy "Users can publish own statuses" on public.zouchat_statuses
 for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Users can delete own statuses" on public.zouchat_statuses;
create policy "Users can delete own statuses" on public.zouchat_statuses
 for delete to authenticated using (user_id = auth.uid());

create table if not exists public.message_read_receipts (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key(message_id,user_id)
);
alter table public.message_read_receipts enable row level security;
drop policy if exists "Conversation members can read receipts" on public.message_read_receipts;
create policy "Conversation members can read receipts" on public.message_read_receipts for select to authenticated
 using (exists (
   select 1 from public.messages m
   where m.id = message_read_receipts.message_id
     and public.is_conversation_member(m.conversation_id, auth.uid())
 ));
drop policy if exists "Users can mark messages read" on public.message_read_receipts;
create policy "Users can mark messages read" on public.message_read_receipts for insert to authenticated
 with check (user_id = auth.uid() and exists (
   select 1 from public.messages m
   where m.id = message_read_receipts.message_id
     and m.sender_id <> auth.uid()
     and public.is_conversation_member(m.conversation_id, auth.uid())
 ));
