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

-- Bucket privé. Les URL signées doivent être générées pour le lecteur autorisé.
-- Cette règle ne donne accès qu'aux objets dont le chemin commence par son propre ID.
drop policy if exists "ZouChat media owners can manage" on storage.objects;
drop policy if exists "ZouChat media owners can read" on storage.objects;
create policy "ZouChat media owners can read"
on storage.objects for select to authenticated
using (
  bucket_id = 'zouchat-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

-- Contrôle des fonctions exposées : pas d'appel anonyme à des fonctions privilégiées.
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
