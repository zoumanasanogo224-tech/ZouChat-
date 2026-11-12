-- ZouChat: security hardening and private call signaling
-- Apply only after disabling "Allow public access" in Supabase Realtime settings.
-- No user data is deleted or rewritten by this migration.

-- 1) Ensure suspended accounts cannot create messages or mutate presence/status/read state.
drop policy if exists "Members can send messages" on public.messages;
create policy "Members can send messages"
on public.messages for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and public.is_conversation_member(conversation_id, (select auth.uid()))
  and not public.is_zouchat_banned()
  and (
    not exists (
      select 1 from public.conversations c
      where c.id = messages.conversation_id
        and c.is_group = true
        and c.group_admins_only_send = true
    )
    or public.is_conversation_admin(conversation_id, (select auth.uid()))
  )
);

drop policy if exists "Users can mark messages read" on public.message_read_receipts;
create policy "Users can mark messages read"
on public.message_read_receipts for insert to authenticated
with check (
  user_id = (select auth.uid())
  and not public.is_zouchat_banned()
  and exists (
    select 1 from public.messages m
    where m.id = message_read_receipts.message_id
      and m.sender_id <> (select auth.uid())
      and public.is_conversation_member(m.conversation_id, (select auth.uid()))
  )
);

drop policy if exists "Users can publish own statuses" on public.zouchat_statuses;
create policy "Users can publish own statuses"
on public.zouchat_statuses for insert to authenticated
with check (user_id = (select auth.uid()) and not public.is_zouchat_banned());

drop policy if exists "Users can delete own statuses" on public.zouchat_statuses;
create policy "Users can delete own statuses"
on public.zouchat_statuses for delete to authenticated
using (user_id = (select auth.uid()) and not public.is_zouchat_banned());

drop policy if exists "presence_insert_own" on public.zouchat_presence;
create policy "presence_insert_own"
on public.zouchat_presence for insert to authenticated
with check (user_id = (select auth.uid()) and not public.is_zouchat_banned());

drop policy if exists "presence_update_own" on public.zouchat_presence;
create policy "presence_update_own"
on public.zouchat_presence for update to authenticated
using (user_id = (select auth.uid()) and not public.is_zouchat_banned())
with check (user_id = (select auth.uid()) and not public.is_zouchat_banned());

drop policy if exists "last_seen_insert_own" on public.zouchat_last_seen;
create policy "last_seen_insert_own"
on public.zouchat_last_seen for insert to authenticated
with check (user_id = (select auth.uid()) and not public.is_zouchat_banned());

drop policy if exists "last_seen_update_own" on public.zouchat_last_seen;
create policy "last_seen_update_own"
on public.zouchat_last_seen for update to authenticated
using (user_id = (select auth.uid()) and not public.is_zouchat_banned())
with check (user_id = (select auth.uid()) and not public.is_zouchat_banned());

-- 2) Add the same server-side suspension guard to privileged write RPCs.
do $$
declare
  v_name text;
  v_oid oid;
  v_definition text;
  v_patched text;
begin
  foreach v_name in array array[
    'create_dm',
    'create_group',
    'add_group_members',
    'remove_group_member',
    'set_group_admin',
    'update_group_settings',
    'consume_view_once_media'
  ] loop
    select p.oid into v_oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = v_name
      and p.prokind = 'f'
    limit 1;

    if v_oid is null then
      raise exception 'Fonction ZouChat manquante: %', v_name;
    end if;

    v_definition := pg_get_functiondef(v_oid);
    if position('public.is_zouchat_banned()' in v_definition) = 0 then
      v_patched := regexp_replace(
        v_definition,
        E'\nbegin\n',
        E'\nbegin\n  if auth.uid() is not null and public.is_zouchat_banned() then\n    raise exception ''Compte suspendu'';\n  end if;\n',
        'i'
      );
      if v_patched = v_definition then
        raise exception 'Impossible d''ajouter le contrôle de suspension à %', v_name;
      end if;
      execute v_patched;
    end if;
  end loop;
end
$$;

-- 3) Protect call signaling with private Realtime channels and membership-based authorization.
drop policy if exists "ZouChat members can receive call broadcasts" on realtime.messages;
create policy "ZouChat members can receive call broadcasts"
on realtime.messages for select to authenticated
using (
  extension = 'broadcast'
  and (select realtime.topic()) ~ '^call:[0-9a-fA-F-]{36}$'
  and exists (
    select 1
    from public.conversations c
    where c.id::text = substring((select realtime.topic()) from 6)
      and public.is_conversation_member(c.id, (select auth.uid()))
      and not public.is_zouchat_banned()
  )
);

drop policy if exists "ZouChat members can send call broadcasts" on realtime.messages;
create policy "ZouChat members can send call broadcasts"
on realtime.messages for insert to authenticated
with check (
  extension = 'broadcast'
  and (select realtime.topic()) ~ '^call:[0-9a-fA-F-]{36}$'
  and exists (
    select 1
    from public.conversations c
    where c.id::text = substring((select realtime.topic()) from 6)
      and public.is_conversation_member(c.id, (select auth.uid()))
      and not public.is_zouchat_banned()
  )
);
