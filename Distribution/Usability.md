# FGOTrack usability review — 4 October 2026

Reviewed on the isolated iPhone 17 / iOS 27 QA simulator. No changes were made to the user's physical phones.

## Observed and verified

- Cold launch without a session opens Create account, with no guest/skip/dismiss action.
- Brand mark, support address and privacy information are present before authentication.
- Invalid credentials produce an inline error; corrected confirmed QA credentials open the app. Signing out immediately returns to the account gate.
- The in-app privacy page opens from the signed-out screen and explains private/shared data and on-device receipt processing.
- Bottom navigation contains exactly Pooled and Personal. Overview, Expenses and Budgets are sections inside each workspace.
- Personal is usable without joining a room. The Pooled tab offers room creation or joining.
- Setting a private Food budget to ₹3,000 immediately updates the dashboard.
- Saving “QA lunch” for ₹120 suggests Food and updates spending to ₹120 and the budget remainder to ₹2,880.
- Personal entries default to Personal. Pooled has no add-expense action until a room is selected.
- The account/room controls are reachable from the profile icon, instead of occupying a third bottom tab.

## Improvements made after review

- Scan receipt is the primary dashboard action and opens the camera immediately on supported devices.
- A photo saves as a receipt draft without mandatory amount/category/name entry. Background OCR/model suggestions never count as spending until confirmation.
- Manual entry focuses the amount automatically, defaults to the current workspace and suggests a category from the merchant. Only amount and a short label are mandatory.
- The no-room screen hides workspace section controls until there is a shared room to display.
- Category budget cards use adaptive backgrounds/text; widget colors also adapt to appearance.
- Previous/next month buttons and password-visibility controls provide 44-point targets; icon buttons have accessibility labels.
- Receipts to review are scoped separately and include older unresolved photos, preventing drafts from disappearing at month boundaries.
- The pool widget excludes personal draft counts and clears its snapshot on sign-out or when no room is selected. Its links explicitly select Pooled and require authentication.
- iPad declares all required interface orientations. App and extension versions match.

## Scope and remaining checks

Camera hardware, real-device keyboard/autofill, very large Dynamic Type, VoiceOver traversal, two physical devices syncing and real email confirmation/recovery need tester checks. Previous receipt QA confirmed OCR and on-device model suggestions from the sample receipt; the current pass verified sign-in and private-budget/manual-entry behavior.

Room creation UI was inspected, but submitting an additional live QA room was declined by automatic approval review. The unsaved form was cancelled. Room creation, joining, membership, transfer and deletion safeguards were instead verified by 46 rollback-only database integration checks.

The manual expense and private budget were also confirmed in live Supabase. The temporary QA account and its two records were removed after sign-out.

The account-deletion function was prepared in Supabase's editor and type-checked locally. Automatic approval review requires user confirmation before deployment because it enables irreversible deletion. It must be deployed and smoke-tested before beta invitations; a source-ready endpoint is not a deployed endpoint.

## Scan-first flow revision

The primary workspace now opens Pooled after sign-in; joining or selecting a room also opens Pooled. Personal is still one bottom-tab tap away.

The workspace title uses a compact, stable navigation bar. The Overview / Expenses / Budgets switcher and month controls live in one shared header. Expense search is an inline list row below that header, eliminating the conditional navigation search bar that shifted the section controls. The selected month is retained across all three sections and is used for manual expenses and contributions.

A persistent bottom Scan receipt button is available throughout all three sections, beside manual entry. The current workspace selects the receipt's source automatically; quick capture displays that source instead of asking for another choice. Successful capture returns a short saved confirmation. Receipt review is labelled Review receipt / Confirm expense. Camera denial offers a direct Settings button and a photo-library fallback.

Flow: sign in → Pooled → create/join a room if needed → Scan receipt → take/use photo → photo saved → review and confirm the suggested amount later. Personal uses the same flow with private storage. Saving a photo alone does not book spending.

Checked Pooled Overview/Expenses and Personal Overview/Expenses/Budgets in an isolated offline simulator harness using production workspace views and local sample data. The title, switcher, month and scan button stayed in the same positions. Verified Personal routing on quick capture and the denied-camera fallback. Search applies to both receipt drafts and booked entries; switching sections dismisses the search keyboard. The harness has no Supabase credentials or live connection, and no guest path was added to the production app.

The release package is refreshed as version 1.0 build 4. Real camera capture remains a physical-device tester check.

## Invitation flow revision

Room owners can invite from the Pooled toolbar or room settings. Invite people opens native iOS sharing automatically; a QR code and Share QR image are available on the invitation screen. Reopening sharing reuses the current valid invitation instead of invalidating links already sent. Replace invitation explicitly revokes the old invitation. Links expire after seven days or twenty new joins.

Recipients open an app link or scan its QR, authenticate if needed, see the server-verified room name/member count, and tap Join room with their name prefilled. The pending invitation persists across relaunch and authentication. Personal expenses remain private. Existing members see Open room; invalid, expired or replaced links show a recoverable error. Manual pasting remains a fallback and opens the same preview.

Native sharing, the QR screen and recipient preview were inspected with an isolated offline harness. The shared QR image was decoded to the exact invitation route using Apple Vision; its white quiet zone is included in the exported image. Production signed-out routing was checked separately. The invitation RPCs were deployed through migration 202610040004_room_invitations.sql and verified with rollback tests: preview grants no ledger access or membership, owner-only sharing, stable tokens, expiration/replacement and anonymous rejection. Foundation checks total 62; database checks total 56.

Current links use fgotrack://invite/<token> and require FGOTrack installed. HTTPS Universal Links and an install landing page require a public domain with Apple's associated-domain configuration. They are not configured; custom-scheme links may not be clickable in every messaging app. See [Apple associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains).
