create table if not exists public.zouchat_push_tokens (
  user_id uuid not null references auth.users(id) on delete cascade,
  fcm_token text not null,
  platform text not null default 'android' check (platform in ('android')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, fcm_token)
);

alter table public.zouchat_push_tokens enable row level security;

drop policy if exists "Users can read their own push tokens" on public.zouchat_push_tokens;
create policy "Users can read their own push tokens"
  on public.zouchat_push_tokens for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can register their own push tokens" on public.zouchat_push_tokens;
create policy "Users can register their own push tokens"
  on public.zouchat_push_tokens for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can update their own push tokens" on public.zouchat_push_tokens;
create policy "Users can update their own push tokens"
  on public.zouchat_push_tokens for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "Users can remove their own push tokens" on public.zouchat_push_tokens;
create policy "Users can remove their own push tokens"
  on public.zouchat_push_tokens for delete to authenticated
  using ((select auth.uid()) = user_id);

grant select, insert, update, delete on public.zouchat_push_tokens to authenticated;
