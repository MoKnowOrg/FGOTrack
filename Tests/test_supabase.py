"""Integration checks against an installed schema. Everything rolls back.
Usage: python Tests/test_supabase.py /path/to/private-connection-config.json
Config accepts psycopg connect kwargs; never commit database passwords.
Requires psycopg[binary].
"""
import json
import sys
import uuid
from pathlib import Path
import psycopg

checks = 0

def check(value, label):
    global checks
    checks += 1
    if not value:
        raise AssertionError(label)

conn = psycopg.connect(**json.loads(Path(sys.argv[1]).read_text()))
try:
    with conn.cursor() as cur:
        owner, member, outsider = [uuid.uuid4() for _ in range(3)]
        for uid in [owner, member, outsider]:
            cur.execute("insert into auth.users(id, email) values (%s,%s)", (uid, f"fgotrack-test-{uid}@example.invalid"))

        def actor(uid, role="authenticated"):
            cur.execute("reset role")
            cur.execute("select set_config('request.jwt.claims', %s, true)", (json.dumps({"sub": str(uid), "role": role}),))
            cur.execute("set local role " + role)  # Fixed internal role values only.

        def scalar(sql, params=()):
            cur.execute(sql, params)
            return cur.fetchone()[0]

        def denied(sql, params=()):
            cur.execute("savepoint forbidden_action")
            try:
                cur.execute(sql, params)
            except psycopg.Error:
                cur.execute("rollback to savepoint forbidden_action")
                cur.execute("release savepoint forbidden_action")
                return True
            cur.execute("release savepoint forbidden_action")
            return False

        def entry(funding="Pooled", modified=100, filename=None, path=None):
            value = dict(id=str(uuid.uuid4()), kind="expense", title="Test bill", amount=15000, date=800000000, category="Food", funding=funding, person="Test", note="", modified=modified, deleted=False)
            if filename: value["receiptFilename"] = filename
            if path: value["receiptPath"] = path
            return value

        def merge(value, room=None):
            return scalar("select public.merge_ledger_entry(%s::jsonb,%s)", (json.dumps(value), room))

        actor(owner)
        room = scalar("select public.create_room(%s,%s)", ("Integration test room", "Owner"))
        check(scalar("select count(*) from public.room_members") == 1, "Owner automatically added")
        token = scalar("select public.create_room_invite(%s)", (room,))
        pooled = entry()
        merge(pooled, room)
        actor(outsider)
        check(scalar("select count(*) from public.rooms") == 0, "Unrelated user cannot read rooms")
        check(scalar("select count(*) from public.ledger_entries") == 0, "Unrelated user cannot read room bills")
        check(denied("select public.merge_ledger_entry(%s::jsonb,%s)", (json.dumps(entry()), room)), "Unrelated user cannot write room bills")
        check(denied("insert into public.rooms(name,owner_id) values ('Forged',%s)", (outsider,)), "Direct room writes blocked")
        actor(member)
        check(scalar("select public.join_room(%s,%s)", (token, "Member")) == room, "Invite joins room")
        check(scalar("select count(*) from public.room_members") == 2, "Members can list housemates")
        check(scalar("select count(*) from public.ledger_entries") == 1, "Member can read pooled bills")
        check(denied("select public.create_room_invite(%s)", (room,)), "Only owner creates invites")
        check(denied("select public.remove_room_member(%s,%s)", (room, owner)), "Member cannot remove owner")
        personal = entry("Personal")
        merge(personal)
        newer = dict(pooled, modified=300, amount=25000)
        merge(newer, room)
        check(merge(dict(pooled, modified=200), room)["amount"] == 25000, "Atomic merge preserves newer edits")
        file = str(uuid.uuid4()) + ".jpg"
        check(scalar("select public.can_access_receipt(%s)", (f"rooms/{room}/{file}",)), "Member can access room receipts")
        check(scalar("select public.can_access_receipt(%s)", (f"personal/{member}/{file}",)), "Personal receipt owner can access")
        check(not scalar("select public.can_access_receipt(%s)", (f"personal/{owner}/{file}",)), "Member cannot access another personal receipt")
        check(not scalar("select public.can_access_receipt(%s)", ("rooms/not-a-uuid/photo.jpg",)), "Malformed paths rejected")
        forged = entry("Personal", filename=file, path=f"personal/{owner}/{file}")
        check(denied("select public.merge_ledger_entry(%s::jsonb,null)", (json.dumps(forged),)), "Forged personal receipt reference blocked")
        invalid = entry(); invalid["amount"] = -1
        check(denied("select public.merge_ledger_entry(%s::jsonb,%s)", (json.dumps(invalid), room)), "Negative amounts rejected")
        actor(owner)
        check(scalar("select count(*) from public.ledger_entries where room_id is null") == 0, "Owner cannot read member's personal bills")
        check(denied("select public.remove_room_member(%s,%s)", (room, owner)), "Owner cannot remove self")
        cur.execute("select public.remove_room_member(%s,%s)", (room, member))
        actor(member)
        check(scalar("select count(*) from public.rooms") == 0, "Removed member cannot read room")
        check(scalar("select count(*) from public.ledger_entries where room_id is not null") == 0, "Removed member cannot read pooled bills")
        check(scalar("select count(*) from public.ledger_entries where room_id is null") == 1, "Removed member keeps personal bills")
        check(not scalar("select public.can_access_receipt(%s)", (f"rooms/{room}/{file}",)), "Removed member loses receipt access")
        check(denied("select public.join_room(%s,%s)", (token, "Member")), "Removal revokes invite codes")
        actor(owner)
        draft = entry(filename=str(uuid.uuid4()) + ".jpg")
        draft.update(kind="receipt", amount=0, suggestedAmount=12500)
        check(merge(draft, room)["kind"] == "receipt", "Pooled receipt inbox accepts zero booked amount")
        draft.update(kind="expense", amount=12500, modified=101)
        check(merge(draft, room)["amount"] == 12500, "Receipt can be confirmed without duplicate ID")
        private_draft = entry("Personal", filename=str(uuid.uuid4()) + ".jpg")
        private_draft.update(kind="receipt", amount=0)
        check(merge(private_draft)["kind"] == "receipt", "Personal receipt draft allowed")
        invalid_draft = entry(); invalid_draft.update(kind="receipt", amount=0)
        check(denied("select public.merge_ledger_entry(%s::jsonb,%s)", (json.dumps(invalid_draft), room)), "Draft must have a receipt photo reference")
        # Personal budgets and deletion privileges must be isolated from housemates.
        personal_budget = entry("Personal"); personal_budget.update(kind="budget", amount=50000)
        check(merge(personal_budget)["amount"] == 50000, "Personal budget accepted without a room")
        actor(outsider)
        check(scalar("select count(*) from public.ledger_entries where room_id is null") == 0, "Personal budgets hidden from unrelated accounts")
        check(denied("select public.prepare_account_deletion(%s)", (owner,)), "Client cannot prepare another user's deletion")
        check(denied("select public.finalize_account_deletion(%s)", (owner,)), "Client cannot finalize account deletion")
        check(denied("select public.transfer_room_ownership(%s,%s)", (room, outsider)), "Outsider cannot transfer room ownership")
        actor(owner)
        fresh_token = scalar("select public.create_room_invite(%s)", (room,))
        actor(member)
        scalar("select public.join_room(%s,%s)", (fresh_token, "Member"))
        actor(owner)
        cur.execute("select public.transfer_room_ownership(%s,%s)", (room, member))
        check(not scalar("select public.is_room_owner(%s)", (room,)), "Previous owner becomes ordinary member")
        check(denied("select public.create_room_invite(%s)", (room,)), "Previous owner cannot invite after transfer")
        actor(member)
        check(scalar("select public.is_room_owner(%s)", (room,)), "Ownership transferred to selected member")
        check(denied("select public.join_room(%s,%s)", (fresh_token, "Member")), "Transfer revokes invitation codes")
        cur.execute("reset role")
        check(denied("select public.prepare_account_deletion(%s)", (member,)), "Owner must transfer before account deletion")
        cur.execute("select public.prepare_account_deletion(%s)", (owner,))
        actor(owner)
        check(scalar("select count(*) from public.ledger_entries") == 0, "Prepared deletion blocks reading personal and room records")
        check(denied("select public.merge_ledger_entry(%s::jsonb,null)", (json.dumps(entry("Personal")),)), "Prepared deletion blocks writes")
        check(not scalar("select public.can_access_receipt(%s)", (f"personal/{owner}/{file}",)), "Prepared deletion blocks private receipt access")
        cur.execute("reset role")
        cur.execute("select public.finalize_account_deletion(%s)", (owner,))
        check(scalar("select count(*) from public.ledger_entries where room_id is null and owner_id=%s", (owner,)) == 0, "Deletion removes private ledger")
        check(scalar("select count(*) from public.ledger_entries where room_id=%s and owner_id=%s", (room, owner)) == 0, "Shared ledger creator anonymized")
        cur.execute("delete from auth.users where id=%s", (owner,))
        actor(member)
        check(scalar("select count(*) from public.ledger_entries where room_id=%s", (room,)) == 2, "Shared expenses survive former owner's deletion")
        # Invite preview exposes room identity only after authentication and token validation.
        actor(member)
        active = scalar("select public.get_or_create_room_invite(%s)", (room,))
        check(scalar("select public.get_or_create_room_invite(%s)", (room,))["token"] == active["token"], "Reopening sharing reuses a valid invitation")
        check(scalar("select public.preview_room_invitation(%s)", (active["token"],))["already_member"], "Existing member sees open-room state")
        actor(outsider)
        preview = scalar("select public.preview_room_invitation(%s)", (active["token"],))
        check(preview["room_name"] == "Integration test room" and preview["member_count"] == 1, "Invitation holder sees room identity and member count")
        check(not preview["already_member"], "Preview does not join automatically")
        check(scalar("select count(*) from public.room_members") == 0, "Preview cannot expose the member list")
        check(denied("select public.get_or_create_room_invite(%s)", (room,)), "Non-owner cannot generate shared invitation")
        check(denied("select public.preview_room_invitation(%s)", (uuid.uuid4(),)), "Forged invitation preview rejected")
        actor(member)
        cur.execute("reset role")
        cur.execute("update public.room_invitations set expires_at=now()-interval '1 minute' where token=%s", (active["token"],))
        actor(member)
        replacement = scalar("select public.get_or_create_room_invite(%s)", (room,))
        check(replacement["token"] != active["token"], "Expired invitation replaced on sharing")
        check(denied("select public.preview_room_invitation(%s)", (active["token"],)), "Expired invitation preview rejected")
        actor(outsider, "anon")
        check(denied("select public.create_room(%s,%s)", ("Anonymous", "Anonymous")), "Anonymous RPC calls blocked")
        check(denied("select public.preview_room_invitation(%s)", (replacement["token"],)), "Anonymous invitation preview blocked")
        cur.execute("reset role")
        check(scalar("select public from storage.buckets where id = 'receipts'") is False, "Receipt bucket is private")
    print(f"Passed {checks} database access and merge checks; all test data rolled back.")
finally:
    conn.rollback()
    conn.close()
