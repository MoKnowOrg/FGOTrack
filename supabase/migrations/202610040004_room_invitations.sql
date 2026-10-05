begin;
-- Opening Share should not invalidate invitations that were already sent.
create function public.get_or_create_room_invite(p_room uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_invite public.room_invitations;
begin
 perform 1 from public.rooms where id=p_room for update;
 if not public.is_room_owner(p_room) then raise exception 'Only the owner can invite people'; end if;
 select * into v_invite from public.room_invitations where room_id=p_room and expires_at>now() and uses<20 order by expires_at desc limit 1;
 if not found then
   delete from public.room_invitations where room_id=p_room;
   insert into public.room_invitations(room_id) values (p_room) returning * into v_invite;
 end if;
 return jsonb_build_object('token',v_invite.token,'expires_at',v_invite.expires_at);
end; $$;
create function public.preview_room_invitation(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_invite public.room_invitations; v_room public.rooms; v_member boolean;
begin
 if not public.is_account_active() then raise exception 'Sign in first'; end if;
 select * into v_invite from public.room_invitations where token=p_token;
 if not found or v_invite.expires_at<=now() or v_invite.uses>=20 then raise exception 'This invitation expired or was replaced. Ask the room owner for a new invitation.'; end if;
 select r.* into v_room from public.rooms r join auth.users u on u.id=r.owner_id where r.id=v_invite.room_id and coalesce((u.raw_app_meta_data->>'fgotrack_deleting')::boolean,false)=false;
 if not found then raise exception 'This room is unavailable'; end if;
 v_member := exists(select 1 from public.room_members where room_id=v_room.id and user_id=auth.uid());
 return jsonb_build_object('room_id',v_room.id,'room_name',v_room.name,'member_count',(select count(*) from public.room_members where room_id=v_room.id),'already_member',v_member);
end; $$;
revoke all on function public.get_or_create_room_invite(uuid), public.preview_room_invitation(uuid) from public,anon;
grant execute on function public.get_or_create_room_invite(uuid), public.preview_room_invitation(uuid) to authenticated;
commit;
