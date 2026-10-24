-- ZouChat : migration pour les médias en vue unique
-- À exécuter une seule fois dans Supabase > SQL Editor.

create or replace function public.consume_view_once_media(p_message_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_message public.messages%rowtype;
  v_payload jsonb;
  v_updated integer;
begin
  if auth.uid() is null then
    raise exception 'Authentification requise';
  end if;

  select * into v_message
    from public.messages
   where id = p_message_id
   for update;

  if not found then
    raise exception 'Message introuvable ou déjà consommé';
  end if;
  if v_message.sender_id = auth.uid() then
    raise exception 'Seul le destinataire peut ouvrir ce média';
  end if;
  if not exists (
    select 1 from public.conversation_members cm
     where cm.conversation_id = v_message.conversation_id
       and cm.user_id = auth.uid()
  ) then
    raise exception 'Accès refusé à cette conversation';
  end if;

  begin
    v_payload := v_message.content::jsonb;
  exception when others then
    raise exception 'Contenu du message invalide';
  end;

  if coalesce((v_payload ->> 'viewOnce')::boolean, false) is not true
     or v_payload ->> 'type' not in ('image', 'video')
     or nullif(v_payload ->> 'path', '') is null then
    raise exception 'Ce média n’est pas disponible en vue unique';
  end if;

  update public.messages
     set content = '{"type":"view_once_consumed"}'
   where id = p_message_id and content = v_message.content;
  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    raise exception 'Ce média a déjà été ouvert';
  end if;

  return jsonb_build_object('path', v_payload ->> 'path', 'type', v_payload ->> 'type');
end;
$$;

revoke all on function public.consume_view_once_media(uuid) from public;
revoke all on function public.consume_view_once_media(uuid) from anon;
grant execute on function public.consume_view_once_media(uuid) to authenticated;
