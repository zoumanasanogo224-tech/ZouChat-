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
