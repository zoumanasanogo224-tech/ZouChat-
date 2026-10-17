-- ZouChat V10 — migration Supabase
-- À exécuter dans Supabase > SQL Editor, dans le projet ZouChat.
-- Ne colle jamais une clé secret/service_role dans l'application.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  created_at timestamptz not null default now()
);
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  created_by uuid references auth.users(id) on delete set null,
  title text,
  is_group boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (conversation_id,user_id)
);
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  content text not null check (char_length(content) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id,created_at);
create index if not exists members_user_idx on public.conversation_members(user_id);

-- Crée le profil automatiquement après une inscription Auth.
create or replace function public.handle_new_zouchat_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare uname text;
begin
  uname := lower(coalesce(new.raw_user_meta_data->>'username',''));
  if uname !~ '^[a-z0-9_.-]{3,24}$' then
    uname := 'user_' || substr(replace(new.id::text,'-',''),1,12);
  end if;
  insert into public.profiles(id,username) values(new.id,uname)
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created_zouchat on auth.users;
create trigger on_auth_user_created_zouchat after insert on auth.users
for each row execute procedure public.handle_new_zouchat_user();

-- Fonction interne utilisée par les règles RLS pour vérifier l'appartenance.
create or replace function public.is_conversation_member(p_conversation_id uuid,p_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public set row_security = off as $$
  select exists(select 1 from public.conversation_members cm where cm.conversation_id=p_conversation_id and cm.user_id=p_user_id);
$$;
revoke all on function public.is_conversation_member(uuid,uuid) from public;
grant execute on function public.is_conversation_member(uuid,uuid) to authenticated;

-- Démarre ou retrouve une discussion privée. Les adhésions ne sont pas ouvertes aux clients directement.
create or replace function public.create_dm(target_user uuid)
returns uuid language plpgsql security definer set search_path = public, auth set row_security = off as $$
declare me uuid := auth.uid(); conv_id uuid;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  if target_user is null or target_user = me then raise exception 'Utilisateur invalide'; end if;
  if not exists(select 1 from public.profiles p where p.id=target_user) then raise exception 'Utilisateur introuvable'; end if;
  select c.id into conv_id
  from public.conversations c
  where c.is_group=false
    and exists(select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=me)
    and exists(select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=target_user)
    and (select count(*) from public.conversation_members x where x.conversation_id=c.id)=2
  order by c.created_at desc limit 1;
  if conv_id is not null then return conv_id; end if;
  insert into public.conversations(created_by,is_group) values(me,false) returning id into conv_id;
  insert into public.conversation_members(conversation_id,user_id) values(conv_id,me),(conv_id,target_user);
  return conv_id;
end;
$$;
revoke all on function public.create_dm(uuid) from public;
grant execute on function public.create_dm(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

drop policy if exists "Profiles are viewable by everyone" on public.profiles;
drop policy if exists "Users can insert their own profile" on public.profiles;
drop policy if exists "Users can update their own profile" on public.profiles;
drop policy if exists "Users can view own profile" on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Profiles are searchable by authenticated users" on public.profiles for select to authenticated using (true);
create policy "Users can insert own profile" on public.profiles for insert to authenticated with check (id=auth.uid());
create policy "Users can update own profile" on public.profiles for update to authenticated using (id=auth.uid()) with check (id=auth.uid());

drop policy if exists "Users can view their conversations" on public.conversations;
drop policy if exists "Members can view conversations" on public.conversations;
drop policy if exists "Users can create conversations" on public.conversations;
create policy "Members can view conversations" on public.conversations for select to authenticated using (public.is_conversation_member(id,auth.uid()));
create policy "Users can create conversations" on public.conversations for insert to authenticated with check (created_by=auth.uid());

drop policy if exists "Users can view conversation members" on public.conversation_members;
drop policy if exists "Members can view membership" on public.conversation_members;
drop policy if exists "Users can join conversations" on public.conversation_members;
create policy "Members can view membership" on public.conversation_members for select to authenticated using (user_id=auth.uid() or public.is_conversation_member(conversation_id,auth.uid()));
-- Aucun INSERT/UPDATE/DELETE client direct : create_dm() gère les membres des DM.

drop policy if exists "Users can view messages in their conversations" on public.messages;
drop policy if exists "Members can read messages" on public.messages;
drop policy if exists "Users can send messages in their conversations" on public.messages;
drop policy if exists "Members can send messages" on public.messages;
create policy "Members can read messages" on public.messages for select to authenticated using (public.is_conversation_member(conversation_id,auth.uid()));
create policy "Members can send messages" on public.messages for insert to authenticated with check (sender_id=auth.uid() and public.is_conversation_member(conversation_id,auth.uid()));

-- Autorise la diffusion en temps réel des nouveaux messages.
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;

-- ZouChat Evolution : stockage privé des médias.
insert into storage.buckets (id, name, public, file_size_limit)
values ('zouchat-media', 'zouchat-media', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;

drop policy if exists "ZouChat media members can upload" on storage.objects;
create policy "ZouChat media members can upload"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'zouchat-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and case
    when (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(((storage.foldername(name))[2])::uuid, (select auth.uid()))
    else false
  end
);

-- Seuls les membres de la conversation peuvent lire les médias privés.
-- Le chemin est uploader_id/conversation_id/nom_du_fichier.
drop policy if exists "ZouChat media owners can read" on storage.objects;
drop policy if exists "ZouChat media conversation members can read" on storage.objects;
create policy "ZouChat media conversation members can read"
on storage.objects for select to authenticated
using (
  bucket_id = 'zouchat-media'
  and case
    when (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(((storage.foldername(name))[2])::uuid, (select auth.uid()))
    else false
  end
);

-- Restreint les fonctions privilegiees exposees par l'API.
revoke execute on function public.create_dm(uuid) from public, anon;
grant execute on function public.create_dm(uuid) to authenticated;
revoke execute on function public.is_conversation_member(uuid, uuid) from public, anon;
grant execute on function public.is_conversation_member(uuid, uuid) to authenticated;
revoke execute on function public.handle_new_zouchat_user() from public, anon, authenticated;

-- Seuls les membres de la conversation peuvent utiliser la signalisation d'appel.
drop policy if exists "ZouChat call members can receive signals" on realtime.messages;
create policy "ZouChat call members can receive signals"
on realtime.messages for select to authenticated
using (
  case
    when realtime.topic() ~* '^call:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(split_part(realtime.topic(), ':', 2)::uuid, (select auth.uid()))
    else false
  end
);

drop policy if exists "ZouChat call members can send signals" on realtime.messages;
create policy "ZouChat call members can send signals"
on realtime.messages for insert to authenticated
with check (
  case
    when realtime.topic() ~* '^call:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(split_part(realtime.topic(), ':', 2)::uuid, (select auth.uid()))
    else false
  end
);


-- ZouChat Evolution : signalements, administration et bannissement applicatif.
create table if not exists public.zouchat_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.zouchat_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references auth.users(id) on delete cascade,
  target_user_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (reason in ('spam','harassment','impersonation','inappropriate_content','scam','other')),
  details text not null default '' check (char_length(details) <= 1200),
  status text not null default 'pending' check (status in ('pending','resolved','dismissed')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_note text not null default ''
);
create index if not exists zouchat_reports_status_created_idx on public.zouchat_reports(status, created_at desc);
create index if not exists zouchat_reports_target_idx on public.zouchat_reports(target_user_id, created_at desc);
create unique index if not exists zouchat_one_pending_report_per_reporter_target
on public.zouchat_reports(reporter_id, target_user_id) where status = 'pending';

create table if not exists public.zouchat_bans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  banned_by uuid not null references auth.users(id) on delete restrict,
  report_id uuid references public.zouchat_reports(id) on delete set null,
  reason text not null,
  banned_at timestamptz not null default now(),
  banned_until timestamptz,
  active boolean not null default true
);

create table if not exists public.zouchat_moderation_actions (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references auth.users(id) on delete restrict,
  target_user_id uuid not null references auth.users(id) on delete cascade,
  report_id uuid references public.zouchat_reports(id) on delete set null,
  action text not null check (action in ('dismiss_report','ban_temporary','ban_permanent','unban')),
  note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists zouchat_moderation_actions_target_idx
on public.zouchat_moderation_actions(target_user_id, created_at desc);

alter table public.zouchat_admins enable row level security;
alter table public.zouchat_reports enable row level security;
alter table public.zouchat_bans enable row level security;
alter table public.zouchat_moderation_actions enable row level security;
revoke all on public.zouchat_admins, public.zouchat_reports, public.zouchat_bans, public.zouchat_moderation_actions from public, anon, authenticated;

create or replace function public.is_zouchat_admin()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists(select 1 from public.zouchat_admins a where a.user_id = (select auth.uid()));
$$;
revoke all on function public.is_zouchat_admin() from public, anon;
grant execute on function public.is_zouchat_admin() to authenticated;

create or replace function public.is_zouchat_banned()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists(
    select 1 from public.zouchat_bans b
    where b.user_id = (select auth.uid())
      and b.active = true
      and (b.banned_until is null or b.banned_until > now())
  );
$$;
revoke all on function public.is_zouchat_banned() from public, anon;
grant execute on function public.is_zouchat_banned() to authenticated;

create or replace function public.get_my_zouchat_ban_status()
returns table(is_banned boolean, banned_until timestamptz, ban_reason text)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if (select auth.uid()) is null then raise exception 'Connexion requise'; end if;
  return query
  select exists(
      select 1 from public.zouchat_bans b
      where b.user_id = (select auth.uid()) and b.active = true
        and (b.banned_until is null or b.banned_until > now())
    ),
    (select b.banned_until from public.zouchat_bans b
      where b.user_id = (select auth.uid()) and b.active = true
      order by b.banned_at desc limit 1),
    (select b.reason from public.zouchat_bans b
      where b.user_id = (select auth.uid()) and b.active = true
      order by b.banned_at desc limit 1);
end;
$$;
revoke all on function public.get_my_zouchat_ban_status() from public, anon;
grant execute on function public.get_my_zouchat_ban_status() to authenticated;

create or replace function public.submit_zouchat_report(p_target_user_id uuid, p_reason text, p_details text default '')
returns uuid language plpgsql security definer set search_path = public, auth as $$
declare me uuid := (select auth.uid()); report_uuid uuid;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  if public.is_zouchat_banned() then raise exception 'Ce compte ne peut pas envoyer de signalement'; end if;
  if p_target_user_id is null or p_target_user_id = me then raise exception 'Compte cible invalide'; end if;
  if p_reason not in ('spam','harassment','impersonation','inappropriate_content','scam','other') then raise exception 'Motif invalide'; end if;
  if not exists(select 1 from public.profiles p where p.id = p_target_user_id) then raise exception 'Utilisateur introuvable'; end if;
  if char_length(coalesce(p_details,'')) > 1200 then raise exception 'Les détails sont trop longs'; end if;
  insert into public.zouchat_reports(reporter_id,target_user_id,reason,details)
  values(me,p_target_user_id,p_reason,coalesce(trim(p_details),''))
  returning id into report_uuid;
  return report_uuid;
exception when unique_violation then
  raise exception 'Tu as déjà un signalement en attente pour ce compte';
end;
$$;
revoke all on function public.submit_zouchat_report(uuid,text,text) from public, anon;
grant execute on function public.submit_zouchat_report(uuid,text,text) to authenticated;

create or replace function public.get_zouchat_reports()
returns table(
  report_id uuid, reporter_username text, target_user_id uuid, target_username text,
  reason text, details text, report_status text, reported_at timestamptz,
  reviewed_at timestamptz, review_note text, banned_until timestamptz, is_currently_banned boolean
)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_zouchat_admin() then raise exception 'Accès réservé à l’administrateur'; end if;
  return query
  select r.id, coalesce(rp.username,'Compte supprimé'), r.target_user_id,
    coalesce(tp.username,'Compte supprimé'), r.reason, r.details, r.status,
    r.created_at, r.reviewed_at, r.review_note, b.banned_until,
    coalesce(b.active and (b.banned_until is null or b.banned_until > now()),false)
  from public.zouchat_reports r
  left join public.profiles rp on rp.id = r.reporter_id
  left join public.profiles tp on tp.id = r.target_user_id
  left join public.zouchat_bans b on b.user_id = r.target_user_id
  order by case when r.status='pending' then 0 else 1 end, r.created_at desc
  limit 200;
end;
$$;
revoke all on function public.get_zouchat_reports() from public, anon;
grant execute on function public.get_zouchat_reports() to authenticated;

create or replace function public.review_zouchat_report(
  p_report_id uuid, p_decision text, p_note text default '', p_duration_days integer default 7
)
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare me uuid := (select auth.uid()); r public.zouchat_reports%rowtype; until_at timestamptz;
begin
  if me is null or not public.is_zouchat_admin() then raise exception 'Action réservée à l’administrateur'; end if;
  if p_decision not in ('dismiss','ban_temporary','ban_permanent') then raise exception 'Décision invalide'; end if;
  if char_length(coalesce(p_note,'')) > 1200 then raise exception 'La note est trop longue'; end if;
  select * into r from public.zouchat_reports where id=p_report_id for update;
  if not found then raise exception 'Signalement introuvable'; end if;
  if r.status <> 'pending' then raise exception 'Ce signalement a déjà été traité'; end if;
  if p_decision='dismiss' then
    update public.zouchat_reports set status='dismissed',reviewed_at=now(),reviewed_by=me,review_note=coalesce(trim(p_note),'') where id=r.id;
    insert into public.zouchat_moderation_actions(admin_id,target_user_id,report_id,action,note)
      values(me,r.target_user_id,r.id,'dismiss_report',coalesce(trim(p_note),''));
  else
    if p_decision='ban_temporary' and (p_duration_days is null or p_duration_days < 1 or p_duration_days > 3650) then
      raise exception 'La durée doit être comprise entre 1 et 3650 jours';
    end if;
    until_at := case when p_decision='ban_permanent' then null else now() + make_interval(days => p_duration_days) end;
    insert into public.zouchat_bans(user_id,banned_by,report_id,reason,banned_at,banned_until,active)
      values(r.target_user_id,me,r.id,coalesce(nullif(trim(p_note),''),r.reason),now(),until_at,true)
    on conflict(user_id) do update set banned_by=excluded.banned_by,report_id=excluded.report_id,
      reason=excluded.reason,banned_at=now(),banned_until=excluded.banned_until,active=true;
    update public.zouchat_reports set status='resolved',reviewed_at=now(),reviewed_by=me,review_note=coalesce(trim(p_note),'') where id=r.id;
    insert into public.zouchat_moderation_actions(admin_id,target_user_id,report_id,action,note)
      values(me,r.target_user_id,r.id,case when p_decision='ban_permanent' then 'ban_permanent' else 'ban_temporary' end,coalesce(trim(p_note),r.reason));
  end if;
  return true;
end;
$$;
revoke all on function public.review_zouchat_report(uuid,text,text,integer) from public, anon;
grant execute on function public.review_zouchat_report(uuid,text,text,integer) to authenticated;

create or replace function public.unban_zouchat_user(p_target_user_id uuid, p_note text default '')
returns boolean language plpgsql security definer set search_path = public, auth as $$
declare me uuid := (select auth.uid());
begin
  if me is null or not public.is_zouchat_admin() then raise exception 'Action réservée à l’administrateur'; end if;
  if p_target_user_id is null then raise exception 'Compte invalide'; end if;
  update public.zouchat_bans set active=false where user_id=p_target_user_id and active=true;
  insert into public.zouchat_moderation_actions(admin_id,target_user_id,action,note)
    values(me,p_target_user_id,'unban',left(coalesce(trim(p_note),''),1200));
  return true;
end;
$$;
revoke all on function public.unban_zouchat_user(uuid,text) from public, anon;
grant execute on function public.unban_zouchat_user(uuid,text) to authenticated;

-- Les comptes bannis sont bloqués au niveau RLS, pas seulement masqués dans l'interface.
drop policy if exists "Profiles are searchable by authenticated users" on public.profiles;
create policy "Profiles are searchable by authenticated users" on public.profiles
for select to authenticated using (not public.is_zouchat_banned());
drop policy if exists "Users can insert own profile" on public.profiles;
create policy "Users can insert own profile" on public.profiles
for insert to authenticated with check (id=(select auth.uid()) and not public.is_zouchat_banned());
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile" on public.profiles
for update to authenticated using (id=(select auth.uid()) and not public.is_zouchat_banned())
with check (id=(select auth.uid()) and not public.is_zouchat_banned());

drop policy if exists "Members can view conversations" on public.conversations;
create policy "Members can view conversations" on public.conversations
for select to authenticated using (public.is_conversation_member(id,(select auth.uid())) and not public.is_zouchat_banned());
drop policy if exists "Users can create conversations" on public.conversations;
create policy "Users can create conversations" on public.conversations
for insert to authenticated with check (created_by=(select auth.uid()) and not public.is_zouchat_banned());

drop policy if exists "Members can view membership" on public.conversation_members;
create policy "Members can view membership" on public.conversation_members
for select to authenticated using (
  (user_id=(select auth.uid()) or public.is_conversation_member(conversation_id,(select auth.uid())))
  and not public.is_zouchat_banned()
);

drop policy if exists "Members can read messages" on public.messages;
create policy "Members can read messages" on public.messages
for select to authenticated using (public.is_conversation_member(conversation_id,(select auth.uid())) and not public.is_zouchat_banned());
drop policy if exists "Members can send messages" on public.messages;
create policy "Members can send messages" on public.messages
for insert to authenticated with check (
  sender_id=(select auth.uid()) and public.is_conversation_member(conversation_id,(select auth.uid()))
  and not public.is_zouchat_banned()
);

create or replace function public.create_dm(target_user uuid)
returns uuid language plpgsql security definer set search_path = public, auth set row_security = off as $$
declare me uuid := (select auth.uid()); conv_id uuid;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  if public.is_zouchat_banned() then raise exception 'Ce compte est banni de ZouChat'; end if;
  if target_user is null or target_user=me then raise exception 'Utilisateur invalide'; end if;
  if not exists(select 1 from public.profiles p where p.id=target_user) then raise exception 'Utilisateur introuvable'; end if;
  select c.id into conv_id from public.conversations c
  where c.is_group=false
    and exists(select 1 from public.conversation_members a where a.conversation_id=c.id and a.user_id=me)
    and exists(select 1 from public.conversation_members b where b.conversation_id=c.id and b.user_id=target_user)
    and (select count(*) from public.conversation_members x where x.conversation_id=c.id)=2
  order by c.created_at desc limit 1;
  if conv_id is not null then return conv_id; end if;
  insert into public.conversations(created_by,is_group) values(me,false) returning id into conv_id;
  insert into public.conversation_members(conversation_id,user_id) values(conv_id,me),(conv_id,target_user);
  return conv_id;
end;
$$;
revoke all on function public.create_dm(uuid) from public, anon;
grant execute on function public.create_dm(uuid) to authenticated;

drop policy if exists "ZouChat media members can upload" on storage.objects;
create policy "ZouChat media members can upload" on storage.objects
for insert to authenticated with check (
  bucket_id='zouchat-media'
  and (storage.foldername(name))[1]=(select auth.uid())::text
  and case when (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(((storage.foldername(name))[2])::uuid,(select auth.uid()))
    else false end
  and not public.is_zouchat_banned()
);
drop policy if exists "ZouChat media conversation members can read" on storage.objects;
create policy "ZouChat media conversation members can read" on storage.objects
for select to authenticated using (
  bucket_id='zouchat-media'
  and case when (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(((storage.foldername(name))[2])::uuid,(select auth.uid()))
    else false end
  and not public.is_zouchat_banned()
);

drop policy if exists "ZouChat call members can receive signals" on realtime.messages;
create policy "ZouChat call members can receive signals" on realtime.messages
for select to authenticated using (
  case when realtime.topic() ~* '^call:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(split_part(realtime.topic(),':',2)::uuid,(select auth.uid()))
    else false end
  and not public.is_zouchat_banned()
);
drop policy if exists "ZouChat call members can send signals" on realtime.messages;
create policy "ZouChat call members can send signals" on realtime.messages
for insert to authenticated with check (
  case when realtime.topic() ~* '^call:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.is_conversation_member(split_part(realtime.topic(),':',2)::uuid,(select auth.uid()))
    else false end
  and not public.is_zouchat_banned()
);

-- Supprime les anciennes policies permissives afin que le bannissement s'applique réellement.
drop policy if exists "Join own membership" on public.conversation_members;
drop policy if exists "Read own memberships" on public.conversation_members;
drop policy if exists "Create conversations" on public.conversations;
drop policy if exists "Members read conversations" on public.conversations;
drop policy if exists "Members read messages" on public.messages;
drop policy if exists "Members send messages" on public.messages;
drop policy if exists "Create own profile" on public.profiles;
drop policy if exists "Read profiles when connected" on public.profiles;
drop policy if exists "Update own profile" on public.profiles;

 
-- ZouChat AI Guardian: technical error monitoring and human-reviewed AI proposals.
create table if not exists public.zouchat_guardian_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  event_type text not null check (event_type in ('client_error','unhandled_rejection','manual_check')),
  severity text not null default 'warning' check (severity in ('info','warning','error','critical')),
  summary text not null check (char_length(summary) between 1 and 1000),
  created_at timestamptz not null default now()
);
alter table public.zouchat_guardian_events enable row level security;
drop policy if exists "Users can submit own guardian events" on public.zouchat_guardian_events;
create policy "Users can submit own guardian events" on public.zouchat_guardian_events
for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "Admins can read guardian events" on public.zouchat_guardian_events;
create policy "Admins can read guardian events" on public.zouchat_guardian_events
for select to authenticated using ((select public.is_zouchat_admin()));

create table if not exists public.zouchat_ai_proposals (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id),
  title text not null check (char_length(title) between 1 and 200),
  summary text not null check (char_length(summary) between 1 and 4000),
  patch text,
  test_plan jsonb not null default '[]'::jsonb,
  status text not null default 'pending_approval'
    check (status in ('pending_approval','approved','rejected','implemented')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id)
);
alter table public.zouchat_ai_proposals enable row level security;
drop policy if exists "Admins can read AI proposals" on public.zouchat_ai_proposals;
create policy "Admins can read AI proposals" on public.zouchat_ai_proposals
for select to authenticated using ((select public.is_zouchat_admin()));
drop policy if exists "Admins can create AI proposals" on public.zouchat_ai_proposals;
create policy "Admins can create AI proposals" on public.zouchat_ai_proposals
for insert to authenticated with check ((select public.is_zouchat_admin()) and created_by = (select auth.uid()));
drop policy if exists "Admins can review AI proposals" on public.zouchat_ai_proposals;
create policy "Admins can review AI proposals" on public.zouchat_ai_proposals
for update to authenticated using ((select public.is_zouchat_admin())) with check ((select public.is_zouchat_admin()));
grant select, insert on public.zouchat_guardian_events to authenticated;
grant select, insert, update on public.zouchat_ai_proposals to authenticated;

alter table public.zouchat_ai_proposals
  add column if not exists pull_request_url text,
  add column if not exists branch_name text;

-- ZouChat: groupes et paramètres inspirés de WhatsApp
alter table public.conversations
  add column if not exists description text not null default '',
  add column if not exists group_admins_only_edit boolean not null default false,
  add column if not exists group_admins_only_send boolean not null default false;
alter table public.conversation_members add column if not exists role text not null default 'member' check (role in ('admin','member'));
update public.conversation_members cm set role='admin' from public.conversations c where c.id=cm.conversation_id and c.is_group=true and c.created_by=cm.user_id and cm.role<>'admin';

create or replace function public.is_conversation_admin(p_conversation_id uuid,p_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path=public set row_security=off as $$
 select exists(select 1 from public.conversation_members cm where cm.conversation_id=p_conversation_id and cm.user_id=p_user_id and cm.role='admin');
$$;
revoke all on function public.is_conversation_admin(uuid,uuid) from public,anon;
grant execute on function public.is_conversation_admin(uuid,uuid) to authenticated;

create or replace function public.create_group(p_title text,p_description text default '',p_usernames text[] default '{}')
returns uuid language plpgsql security definer set search_path=public,auth set row_security=off as $$
declare me uuid:=auth.uid(); conv_id uuid; uname text; target_id uuid; missing text[]:='{}'; clean_title text:=btrim(coalesce(p_title,'')); clean_description text:=btrim(coalesce(p_description,'')); total_count integer:=1;
begin
 if me is null then raise exception 'Connexion requise'; end if;
 if char_length(clean_title)<1 or char_length(clean_title)>60 then raise exception 'Le nom du groupe doit contenir de 1 à 60 caractères'; end if;
 if char_length(clean_description)>500 then raise exception 'La description ne peut pas dépasser 500 caractères'; end if;
 if coalesce(cardinality(p_usernames),0)>255 then raise exception 'Un groupe peut contenir au maximum 256 membres'; end if;
 insert into public.conversations(created_by,title,description,is_group) values(me,clean_title,clean_description,true) returning id into conv_id;
 insert into public.conversation_members(conversation_id,user_id,role) values(conv_id,me,'admin');
 foreach uname in array coalesce(p_usernames,'{}') loop
  uname:=lower(btrim(regexp_replace(coalesce(uname,''),'^@','')));
  if uname='' then continue; end if;
  select p.id into target_id from public.profiles p where p.username=uname;
  if target_id is null then missing:=array_append(missing,uname);
  elsif target_id<>me then insert into public.conversation_members(conversation_id,user_id,role) values(conv_id,target_id,'member') on conflict(conversation_id,user_id) do nothing; end if;
  target_id:=null;
 end loop;
 select count(*) into total_count from public.conversation_members where conversation_id=conv_id;
 if cardinality(missing)>0 then raise exception 'Nom(s) d’utilisateur introuvable(s) : %',array_to_string(missing,', '); end if;
 if total_count<2 then raise exception 'Ajoute au moins un autre membre avec son nom d’utilisateur exact'; end if;
 return conv_id;
end; $$;
revoke all on function public.create_group(text,text,text[]) from public,anon;
grant execute on function public.create_group(text,text,text[]) to authenticated;

create or replace function public.update_group_settings(p_conversation_id uuid,p_title text,p_description text,p_admins_only_edit boolean,p_admins_only_send boolean)
returns void language plpgsql security definer set search_path=public,auth set row_security=off as $$
declare me uuid:=auth.uid(); is_admin boolean; current_only_edit boolean; current_only_send boolean;
begin
 if me is null then raise exception 'Connexion requise'; end if;
 if not exists(select 1 from public.conversations c where c.id=p_conversation_id and c.is_group=true) then raise exception 'Groupe introuvable'; end if;
 if not public.is_conversation_member(p_conversation_id,me) then raise exception 'Tu ne fais pas partie de ce groupe'; end if;
 is_admin:=public.is_conversation_admin(p_conversation_id,me);
 select c.group_admins_only_edit,c.group_admins_only_send into current_only_edit,current_only_send from public.conversations c where c.id=p_conversation_id;
 if not is_admin and (current_only_edit or p_admins_only_edit is distinct from current_only_edit or p_admins_only_send is distinct from current_only_send) then raise exception 'Seuls les administrateurs peuvent modifier ces paramètres'; end if;
 if char_length(btrim(coalesce(p_title,'')))<1 or char_length(btrim(p_title))>60 then raise exception 'Le nom du groupe doit contenir de 1 à 60 caractères'; end if;
 if char_length(coalesce(p_description,''))>500 then raise exception 'La description ne peut pas dépasser 500 caractères'; end if;
 update public.conversations set title=btrim(p_title),description=btrim(coalesce(p_description,'')),group_admins_only_edit=case when is_admin then coalesce(p_admins_only_edit,false) else group_admins_only_edit end,group_admins_only_send=case when is_admin then coalesce(p_admins_only_send,false) else group_admins_only_send end where id=p_conversation_id;
end; $$;
revoke all on function public.update_group_settings(uuid,text,text,boolean,boolean) from public,anon;
grant execute on function public.update_group_settings(uuid,text,text,boolean,boolean) to authenticated;

create or replace function public.add_group_members(p_conversation_id uuid,p_usernames text[])
returns integer language plpgsql security definer set search_path=public,auth set row_security=off as $$
declare me uuid:=auth.uid(); uname text; target_id uuid; missing text[]:='{}'; added integer:=0;
begin
 if me is null then raise exception 'Connexion requise'; end if;
 if not public.is_conversation_admin(p_conversation_id,me) then raise exception 'Seuls les administrateurs peuvent ajouter des membres'; end if;
 if not exists(select 1 from public.conversations where id=p_conversation_id and is_group=true) then raise exception 'Groupe introuvable'; end if;
 if coalesce(cardinality(p_usernames),0)>100 then raise exception 'Ajoute au maximum 100 noms à la fois'; end if;
 foreach uname in array coalesce(p_usernames,'{}') loop
  uname:=lower(btrim(regexp_replace(coalesce(uname,''),'^@','')));
  if uname='' then continue; end if;
  select id into target_id from public.profiles where username=uname;
  if target_id is null then missing:=array_append(missing,uname);
  elsif not exists(select 1 from public.conversation_members where conversation_id=p_conversation_id and user_id=target_id) then insert into public.conversation_members(conversation_id,user_id,role) values(p_conversation_id,target_id,'member') on conflict(conversation_id,user_id) do nothing; added:=added+1; end if;
  target_id:=null;
 end loop;
 if cardinality(missing)>0 then raise exception 'Nom(s) introuvable(s) : %',array_to_string(missing,', '); end if;
 return added;
end; $$;
revoke all on function public.add_group_members(uuid,text[]) from public,anon;
grant execute on function public.add_group_members(uuid,text[]) to authenticated;

create or replace function public.remove_group_member(p_conversation_id uuid,p_target_user uuid)
returns void language plpgsql security definer set search_path=public,auth set row_security=off as $$
declare me uuid:=auth.uid(); target_role text; admins integer;
begin
 if me is null then raise exception 'Connexion requise'; end if;
 if not public.is_conversation_member(p_conversation_id,me) then raise exception 'Tu ne fais pas partie de ce groupe'; end if;
 if me<>p_target_user and not public.is_conversation_admin(p_conversation_id,me) then raise exception 'Seuls les administrateurs peuvent retirer un autre membre'; end if;
 select role into target_role from public.conversation_members where conversation_id=p_conversation_id and user_id=p_target_user;
 if target_role is null then raise exception 'Membre introuvable'; end if;
 if target_role='admin' then select count(*) into admins from public.conversation_members where conversation_id=p_conversation_id and role='admin'; if admins<=1 then raise exception 'Le groupe doit conserver au moins un administrateur'; end if; end if;
 delete from public.conversation_members where conversation_id=p_conversation_id and user_id=p_target_user;
end; $$;
revoke all on function public.remove_group_member(uuid,uuid) from public,anon;
grant execute on function public.remove_group_member(uuid,uuid) to authenticated;

create or replace function public.set_group_admin(p_conversation_id uuid,p_target_user uuid,p_make_admin boolean)
returns void language plpgsql security definer set search_path=public,auth set row_security=off as $$
declare me uuid:=auth.uid(); target_role text; admins integer;
begin
 if me is null then raise exception 'Connexion requise'; end if;
 if not public.is_conversation_admin(p_conversation_id,me) then raise exception 'Seuls les administrateurs peuvent modifier les rôles'; end if;
 select role into target_role from public.conversation_members where conversation_id=p_conversation_id and user_id=p_target_user;
 if target_role is null then raise exception 'Membre introuvable'; end if;
 if p_make_admin then update public.conversation_members set role='admin' where conversation_id=p_conversation_id and user_id=p_target_user;
 else select count(*) into admins from public.conversation_members where conversation_id=p_conversation_id and role='admin'; if target_role='admin' and admins<=1 then raise exception 'Le groupe doit conserver au moins un administrateur'; end if; update public.conversation_members set role='member' where conversation_id=p_conversation_id and user_id=p_target_user; end if;
end; $$;
revoke all on function public.set_group_admin(uuid,uuid,boolean) from public,anon;
grant execute on function public.set_group_admin(uuid,uuid,boolean) to authenticated;

drop policy if exists "Users can join conversations" on public.conversation_members;
drop policy if exists "Users can manage conversation members" on public.conversation_members;
drop policy if exists "Members can send messages" on public.messages;
create policy "Members can send messages" on public.messages for insert to authenticated with check (
 sender_id=auth.uid() and public.is_conversation_member(conversation_id,auth.uid()) and
 (not exists(select 1 from public.conversations c where c.id=conversation_id and c.is_group=true and c.group_admins_only_send=true) or public.is_conversation_admin(conversation_id,auth.uid()))
);
do $$ begin alter publication supabase_realtime add table public.conversation_members; exception when duplicate_object then null; end $$;

