begin;
alter table public.ledger_entries alter column owner_id drop not null;
alter table public.ledger_entries drop constraint ledger_entries_owner_id_fkey;
alter table public.ledger_entries add constraint ledger_entries_owner_id_fkey foreign key (owner_id) references auth.users(id) on delete set null;

create function public.is_account_active() returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from auth.users where id = auth.uid() and coalesce((raw_app_meta_data->>'fgotrack_deleting')::boolean,false) = false);
$$;
create or replace function public.is_room_member(p_room uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select public.is_account_active() and exists(select 1 from public.room_members where room_id = p_room and user_id = auth.uid());
$$;
create or replace function public.is_room_owner(p_room uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select public.is_account_active() and exists(select 1 from public.rooms where id = p_room and owner_id = auth.uid());
$$;
drop policy entries_read on public.ledger_entries;
create policy entries_read on public.ledger_entries for select to authenticated using (
 public.is_account_active() and ((room_id is null and owner_id = auth.uid()) or (room_id is not null and public.is_room_member(room_id)))
);
create function public.transfer_room_ownership(p_room uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 perform 1 from public.rooms where id=p_room for update;
 if not public.is_room_owner(p_room) then raise exception 'Only the owner can transfer ownership'; end if;
 if not exists(select 1 from public.room_members m join auth.users u on u.id=m.user_id where m.room_id=p_room and m.user_id=p_user and coalesce((u.raw_app_meta_data->>'fgotrack_deleting')::boolean,false)=false) then raise exception 'Choose an active member of this room'; end if;
 update public.rooms set owner_id=p_user where id=p_room;
 delete from public.room_invitations where room_id=p_room;
end; $$;

-- Called only by the authenticated deletion Edge Function using its server key.
create function public.prepare_account_deletion(p_user uuid) returns uuid[]
language plpgsql security definer set search_path = '' as $$
declare v_rooms uuid[];
begin
 perform 1 from auth.users where id=p_user for update;
 if not found then raise exception 'Account not found'; end if;
 perform 1 from public.rooms where owner_id=p_user for update;
 if exists(select 1 from public.rooms r join public.room_members m on m.room_id=r.id where r.owner_id=p_user and m.user_id<>p_user) then raise exception 'Transfer room ownership to a housemate before deleting your account'; end if;
 select coalesce(array_agg(id),array[]::uuid[]) into v_rooms from public.rooms where owner_id=p_user;
 update auth.users set raw_app_meta_data=coalesce(raw_app_meta_data,'{}'::jsonb) || '{"fgotrack_deleting":true}'::jsonb where id=p_user;
 delete from public.room_invitations where room_id=any(v_rooms);
 return v_rooms;
end; $$;
create function public.finalize_account_deletion(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if not exists(select 1 from auth.users where id=p_user and raw_app_meta_data->>'fgotrack_deleting'='true') then raise exception 'Deletion has not been prepared'; end if;
 if exists(select 1 from public.rooms r join public.room_members m on m.room_id=r.id where r.owner_id=p_user and m.user_id<>p_user) then raise exception 'Transfer room ownership first'; end if;
 if exists(select 1 from storage.objects where bucket_id='receipts' and (name like 'personal/'||p_user::text||'/%' or exists(select 1 from public.rooms r where r.owner_id=p_user and name like 'rooms/'||r.id::text||'/%'))) then raise exception 'Receipt cleanup must finish first'; end if;
 delete from public.ledger_entries where room_id is null and owner_id=p_user;
 delete from public.rooms where owner_id=p_user;
 update public.ledger_entries set owner_id=null where owner_id=p_user;
 -- Retain shared photos but clear uploader ownership so Auth can remove the user.
 update storage.objects set owner=null,owner_id=null where bucket_id='receipts' and (owner=p_user or owner_id=p_user::text);
end; $$;
revoke all on function public.prepare_account_deletion(uuid), public.finalize_account_deletion(uuid) from public, anon, authenticated;
grant execute on function public.prepare_account_deletion(uuid), public.finalize_account_deletion(uuid) to service_role;
revoke all on function public.is_account_active(), public.transfer_room_ownership(uuid,uuid) from public,anon;
grant execute on function public.is_account_active(), public.transfer_room_ownership(uuid,uuid) to authenticated;
create or replace function public.create_room(p_name text, p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 if not public.is_account_active() then raise exception 'Sign in first'; end if;
 if (select count(*) from public.rooms where owner_id = auth.uid()) >= 10 then raise exception 'Room creation limit reached'; end if;
 insert into public.rooms(name, owner_id) values (trim(p_name), auth.uid()) returning id into v_id;
 insert into public.room_members(room_id, user_id, display_name) values (v_id, auth.uid(), trim(p_display_name));
 return v_id;
end; $$;
create or replace function public.join_room(p_token uuid, p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_invite public.room_invitations;
begin
 if not public.is_account_active() then raise exception 'Sign in first'; end if;
 select * into v_invite from public.room_invitations where token = p_token for update;
 if not found or v_invite.expires_at <= now() or v_invite.uses >= 20 then raise exception 'Invitation is invalid, expired, or full'; end if;
 if not exists(select 1 from public.rooms r join auth.users u on u.id=r.owner_id where r.id=v_invite.room_id and coalesce((u.raw_app_meta_data->>'fgotrack_deleting')::boolean,false)=false) then raise exception 'Room is unavailable'; end if;
 if not exists(select 1 from public.room_members where room_id = v_invite.room_id and user_id = auth.uid()) then
   insert into public.room_members(room_id, user_id, display_name) values (v_invite.room_id, auth.uid(), trim(p_display_name));
   update public.room_invitations set uses = uses + 1 where token = p_token;
 end if;
 return v_invite.room_id;
end; $$;
create or replace function public.can_access_receipt(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_parts text[];
begin
 if not public.is_account_active() then return false; end if;
 v_parts := string_to_array(p_name, '/');
 if array_length(v_parts, 1) <> 3 or v_parts[3] !~ '^[0-9a-fA-F-]{36}\.jpg$' then return false; end if;
 if v_parts[1] = 'personal' then return v_parts[2] = auth.uid()::text; end if;
 if v_parts[1] = 'rooms' and v_parts[2] ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
   return public.is_room_member(v_parts[2]::uuid);
 end if;
 return false;
end; $$;
-- Save photos before details are resolved. Drafts never book spending.
create or replace function public.merge_ledger_entry(p_entry jsonb, p_room uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_room uuid; v_scope text; v_result jsonb; v_amount numeric; v_modified numeric; v_path text; v_file text;
begin
 if not public.is_account_active() then raise exception 'Sign in with an active account first'; end if;
 if jsonb_typeof(p_entry) <> 'object'
    or coalesce(p_entry->>'id', '') = '' or length(p_entry->>'id') > 200
    or coalesce(p_entry->>'kind', '') not in ('expense', 'contribution', 'budget', 'receipt')
    or coalesce(p_entry->>'funding', '') not in ('Pooled', 'Personal')
    or jsonb_typeof(p_entry->'amount') is distinct from 'number'
    or jsonb_typeof(p_entry->'modified') is distinct from 'number'
    or jsonb_typeof(p_entry->'date') is distinct from 'number'
    or jsonb_typeof(p_entry->'deleted') is distinct from 'boolean'
    or coalesce(length(trim(p_entry->>'title')), 0) not between 1 and 500
    or coalesce(p_entry->>'category', '') not in ('Rent','Food','Cafes & coworking','Travel','Utilities','Miscellaneous')
 then raise exception 'Invalid ledger entry'; end if;
 v_amount := (p_entry->>'amount')::numeric;
 v_modified := (p_entry->>'modified')::numeric;
 if v_amount < 0 or v_amount > 100000000000 or v_amount <> trunc(v_amount)
    or (v_amount = 0 and p_entry->>'kind' not in ('budget', 'receipt')) then raise exception 'Invalid amount'; end if;
 if p_entry->>'kind' = 'receipt' and (v_amount <> 0 or coalesce(p_entry->>'receiptFilename', '') !~ '^[0-9a-fA-F-]{36}\.jpg$') then raise exception 'Receipt drafts require a photo and zero booked amount'; end if;
 if p_entry->>'funding' = 'Personal' then
   if p_entry->>'kind' not in ('expense', 'receipt', 'budget') then raise exception 'Personal contributions are not supported'; end if;
   v_scope := 'user/' || auth.uid()::text;
 else
   if p_room is null or not public.is_room_member(p_room) then raise exception 'You are not a member of this room'; end if;
   v_room := p_room; v_scope := 'room/' || p_room::text;
 end if;
 v_path := p_entry->>'receiptPath'; v_file := p_entry->>'receiptFilename';
 if v_path is not null then
   if v_file is null or v_file !~ '^[0-9a-fA-F-]{36}\.jpg$'
      or v_path <> (case when v_room is null then 'personal/' || auth.uid()::text else 'rooms/' || v_room::text end) || '/' || v_file
   then raise exception 'Invalid receipt path'; end if;
 end if;
 insert into public.ledger_entries(scope_key, id, room_id, owner_id, payload, modified)
 values (v_scope, p_entry->>'id', v_room, auth.uid(), p_entry, v_modified)
 on conflict (scope_key, id) do update set payload = excluded.payload, modified = excluded.modified
 where excluded.modified > public.ledger_entries.modified;
 select payload into v_result from public.ledger_entries where scope_key = v_scope and id = p_entry->>'id';
 return v_result;
end; $$;


commit;
