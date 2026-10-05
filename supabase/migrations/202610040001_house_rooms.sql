-- Run once in the Supabase SQL editor, or apply with `supabase db push`.
begin;
create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 80),
  owner_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create table public.room_members (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (length(trim(display_name)) between 1 and 80),
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index room_members_user_idx on public.room_members(user_id);
create table public.room_invitations (
  token uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '7 days',
  uses integer not null default 0 check (uses between 0 and 20)
);
create table public.ledger_entries (
  scope_key text not null,
  id text not null check (length(id) between 1 and 200),
  room_id uuid references public.rooms(id) on delete cascade,
  owner_id uuid not null references auth.users(id),
  payload jsonb not null,
  modified numeric not null,
  primary key (scope_key, id),
  check (scope_key = case when room_id is null then 'user/' || owner_id::text else 'room/' || room_id::text end)
);
create index ledger_room_idx on public.ledger_entries(room_id);
create index ledger_personal_idx on public.ledger_entries(owner_id) where room_id is null;

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.room_invitations enable row level security;
alter table public.ledger_entries enable row level security;

create function public.is_room_member(p_room uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.room_members where room_id = p_room and user_id = auth.uid());
$$;
create function public.is_room_owner(p_room uuid) returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.rooms where id = p_room and owner_id = auth.uid());
$$;
create policy rooms_read on public.rooms for select to authenticated using (public.is_room_member(id));
create policy members_read on public.room_members for select to authenticated using (public.is_room_member(room_id));
create policy entries_read on public.ledger_entries for select to authenticated using (
 (room_id is null and owner_id = auth.uid()) or (room_id is not null and public.is_room_member(room_id))
);
-- Clients cannot mutate membership, invitations, or entries directly. Only validated RPCs write.
revoke all on public.rooms, public.room_members, public.room_invitations, public.ledger_entries from anon, authenticated;
grant select on public.rooms, public.room_members, public.ledger_entries to authenticated;

create function public.create_room(p_name text, p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if (select count(*) from public.rooms where owner_id = auth.uid()) >= 10 then raise exception 'Room creation limit reached'; end if;
 insert into public.rooms(name, owner_id) values (trim(p_name), auth.uid()) returning id into v_id;
 insert into public.room_members(room_id, user_id, display_name) values (v_id, auth.uid(), trim(p_display_name));
 return v_id;
end; $$;
create function public.create_room_invite(p_room uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_token uuid;
begin
 if not public.is_room_owner(p_room) then raise exception 'Only the owner can invite people'; end if;
 -- Creating a fresh code revokes all previous codes for this room.
 delete from public.room_invitations where room_id = p_room;
 insert into public.room_invitations(room_id) values (p_room) returning token into v_token;
 return v_token;
end; $$;
create function public.join_room(p_token uuid, p_display_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_invite public.room_invitations;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into v_invite from public.room_invitations where token = p_token for update;
 if not found or v_invite.expires_at <= now() or v_invite.uses >= 20 then raise exception 'Invitation is invalid, expired, or full'; end if;
 if not exists(select 1 from public.room_members where room_id = v_invite.room_id and user_id = auth.uid()) then
   insert into public.room_members(room_id, user_id, display_name) values (v_invite.room_id, auth.uid(), trim(p_display_name));
   update public.room_invitations set uses = uses + 1 where token = p_token;
 end if;
 return v_invite.room_id;
end; $$;
create function public.remove_room_member(p_room uuid, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_room_owner(p_room) then raise exception 'Only the owner can remove members'; end if;
 if p_user = auth.uid() then raise exception 'The room owner cannot be removed'; end if;
 delete from public.room_members where room_id = p_room and user_id = p_user;
 -- Revoke outstanding invite codes so a removed member cannot reuse one.
 delete from public.room_invitations where room_id = p_room;
end; $$;

create function public.merge_ledger_entry(p_entry jsonb, p_room uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_room uuid; v_scope text; v_result jsonb; v_amount numeric; v_modified numeric; v_path text; v_file text;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 if jsonb_typeof(p_entry) <> 'object'
    or coalesce(p_entry->>'id', '') = '' or length(p_entry->>'id') > 200
    or coalesce(p_entry->>'kind', '') not in ('expense', 'contribution', 'budget')
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
    or (v_amount = 0 and p_entry->>'kind' <> 'budget') then raise exception 'Invalid amount'; end if;
 if p_entry->>'funding' = 'Personal' then
   if p_entry->>'kind' <> 'expense' then raise exception 'Only expenses may be personal'; end if;
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

-- Private JPEG objects. No publicly readable receipt URLs.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 10485760, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
create function public.can_access_receipt(p_name text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_parts text[];
begin
 v_parts := string_to_array(p_name, '/');
 if array_length(v_parts, 1) <> 3 or v_parts[3] !~ '^[0-9a-fA-F-]{36}\.jpg$' then return false; end if;
 if v_parts[1] = 'personal' then return v_parts[2] = auth.uid()::text; end if;
 if v_parts[1] = 'rooms' and v_parts[2] ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
   return public.is_room_member(v_parts[2]::uuid);
 end if;
 return false;
end; $$;
create policy receipt_read on storage.objects for select to authenticated using (bucket_id = 'receipts' and public.can_access_receipt(name));
create policy receipt_insert on storage.objects for insert to authenticated with check (bucket_id = 'receipts' and public.can_access_receipt(name));
-- Immutable uploads: no UPDATE policy. Replacement photos get new UUID filenames.
create policy receipt_delete on storage.objects for delete to authenticated using (bucket_id = 'receipts' and public.can_access_receipt(name) and owner_id = auth.uid()::text);

revoke all on function public.is_room_member(uuid), public.is_room_owner(uuid), public.create_room(text,text), public.create_room_invite(uuid), public.join_room(uuid,text), public.remove_room_member(uuid,uuid), public.merge_ledger_entry(jsonb,uuid), public.can_access_receipt(text) from public, anon;
grant execute on function public.is_room_member(uuid), public.is_room_owner(uuid), public.create_room(text,text), public.create_room_invite(uuid), public.join_room(uuid,text), public.remove_room_member(uuid,uuid), public.merge_ledger_entry(jsonb,uuid), public.can_access_receipt(text) to authenticated;
commit;
