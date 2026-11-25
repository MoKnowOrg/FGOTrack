-- Lets a non-owner member leave a room on their own. Apply with `supabase db push` after review.
begin;
create function public.leave_room(p_room uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 -- Lock the room so a concurrent ownership transfer to this caller cannot leave the room ownerless.
 perform 1 from public.rooms where id = p_room for update;
 if not public.is_room_member(p_room) then raise exception 'You are not a member of this room'; end if;
 if public.is_room_owner(p_room) then raise exception 'Transfer ownership to another member before leaving'; end if;
 -- Only the caller's own membership is removed. Pooled entries stay with the room; personal entries are untouched.
 delete from public.room_members where room_id = p_room and user_id = auth.uid();
end; $$;
revoke all on function public.leave_room(uuid) from public, anon;
grant execute on function public.leave_room(uuid) to authenticated;
commit;
