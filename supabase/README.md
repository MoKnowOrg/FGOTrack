# Supabase setup

The migration `migrations/202610040001_house_rooms.sql` has been applied to the supplied project. It creates `rooms`, `room_members`, `room_invitations`, `ledger_entries`, validated RPCs, and a private `receipts` bucket. Do not rerun this initial migration against an already initialized database; use subsequent migrations for changes.

The iOS app uses the official Supabase Swift SDK, pinned to 2.55.3. `FGOTrack/Info.plist` contains the project URL and **publishable** key. This client key is intended to be included in the application. Database passwords and service-role keys are never app configuration.

## Authentication configuration still required

Email sign-in is enabled in the supplied project. Google was disabled when checked.

1. In Supabase → Authentication → URL Configuration, add `fgotrack://auth/callback` to Redirect URLs. This is needed for Google OAuth and email magic links. The app registers the `fgotrack` URL scheme.
2. In Google Cloud, create an OAuth **Web application** client. Configure its authorized redirect URI as `https://cmhgcqydkrbuxifqyxzi.supabase.co/auth/v1/callback` (or the callback shown in your Supabase Google provider settings).
3. In Supabase → Authentication → Sign In / Providers → Google, enable Google and enter that client ID and client secret. Keep the secret in Supabase, not the iOS app.
4. Configure the OAuth consent screen and allowed test users if your Google app is still in testing.
5. For email/password accounts, create an account in the app, confirm the email if required by your project, then sign in. Configure SMTP if needed for reliable confirmation and magic-link delivery.

References: [Supabase Google setup](https://supabase.com/docs/guides/auth/social-login/auth-google), [Swift OAuth](https://supabase.com/docs/reference/swift/auth-signinwithoauth).

## Room usage

Sign in → Pooled → Create a room, or open Account Settings. The owner taps Invite people to open native sharing, or shows/shares a QR code. Housemates open the invitation, sign in if needed, review the verified room, and tap Join room with their name prefilled. A pending invitation survives relaunch and sign-in. Links expire after seven days and permit up to twenty new members. Reopening sharing retains a valid invitation; Replace invitation explicitly revokes the previous link. Removing a member also revokes active invitations. Migration `202610040004_room_invitations.sql` is applied and provides owner-only stable invitation creation and authenticated preview without membership or ledger access.

App links currently use `fgotrack://invite/<token>` and require the app installed. Pasting a link or legacy UUID is a fallback. HTTPS Universal Links and an install landing page require a public domain and associated-domain configuration; they are not configured yet. Custom-scheme link clickability varies across messaging apps.

All current room members may read and edit the pooled ledger and access pooled receipt photos. Only the owner manages invitations and removes members. Personal bills, budgets and receipts are scoped to `auth.uid()` and remain private, including from the room owner. A removed member cannot retrieve new server data, but downloaded copies on their device cannot be remotely erased.

Room and membership mutations have no direct client write grants. Authenticated users call validated security-definer functions with a fixed empty search path. Membership is checked inside every pooled-entry write. Ledger merging compares modification times atomically in PostgreSQL so older writes cannot overwrite newer records. [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security) and [Storage access control](https://supabase.com/docs/guides/storage/security/access-control) describe the underlying access model.

## Receipts

Camera or PhotosPicker → attach JPEG → optional on-device Vision OCR → review suggested total → save. Photos are normalized and resized to a maximum 2,000-pixel longest edge. They save locally before network sync; private bucket uploads retry on the next sync. Personal files use `personal/<user UUID>/<photo UUID>.jpg`; pooled files use `rooms/<room UUID>/<photo UUID>.jpg`. Photos download through authenticated requests; there are no public receipt URLs. Storage limits uploads to JPEGs under 10 MiB.

Photos are immutable: replacement creates a new filename. Removing a photo or bill hides its attachment, but old objects are retained in storage; no automatic retention/garbage-collection job is included. JSON exports contain receipt references, not image bytes.

OCR uses Apple's [Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest), with no external OCR service or API fee. It looks for labelled totals, prefers grand/payable totals, excludes subtotal/tax/savings labels, and leaves conflicting totals for manual entry. Recognition does not automatically change or save the amount. A 20-second timeout and cancellation handling keep manual entry available if the system model is slow or unavailable.

## Integration checks

`Tests/test_supabase.py` runs against the installed schema with `psycopg[binary]`. Supply a private JSON connection configuration outside the repo. It uses temporary users/rooms within a transaction and always rolls back. It sends no emails. Checks cover unauthorized writes, personal isolation, room invitations, owner-only actions, removed-member access, private receipt paths, and atomic merges.

Never commit the connection configuration. No password is present in the migration or application source.


## Account lifecycle and personal budgets

Migration `202610040003_personal_budgets_accounts.sql` is applied. It adds private budget writes, ownership transfer, active-account checks and service-only account-deletion RPCs. Never expose a service-role key in iOS.

`functions/delete-account/index.ts` is a type-checked Deno endpoint. It verifies the bearer token using Auth.getUser, derives the user ID exclusively from that result, blocks data access during deletion, removes private photo files through Storage, retains shared records while clearing creator/uploader ownership, and calls Auth.admin.deleteUser. Owners must transfer rooms with other members first. A failed cleanup may be retried; contact support if it persists.

Deployment (requires an authorized Supabase CLI login):

```sh
supabase functions deploy delete-account --project-ref cmhgcqydkrbuxifqyxzi --no-verify-jwt
```

Gateway JWT verification is disabled because the endpoint itself validates the token with Auth, supporting current signing keys. Deployment through Dashboard → Edge Functions → Via Editor is also supported. Use the same source and configure the gateway setting accordingly. Default Supabase server environment variables provide the service key; no additional third-party secret is needed.

Email/password signup is required; there is no guest ledger. The in-app policy is available before signup and in Account Settings. Apple/Google buttons are discovered from enabled provider settings; Google appears alongside Apple. Confirm the auth redirect URL and email delivery before inviting testers.
