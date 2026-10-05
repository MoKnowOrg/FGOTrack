-- Save photos before details are resolved. Drafts never book spending.
create or replace function public.merge_ledger_entry(p_entry jsonb, p_room uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_room uuid; v_scope text; v_result jsonb; v_amount numeric; v_modified numeric; v_path text; v_file text;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
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
   if p_entry->>'kind' not in ('expense', 'receipt') then raise exception 'Only expenses and receipt drafts may be personal'; end if;
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

