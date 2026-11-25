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

## Budget colors and usability review — 5 October 2026

Budget status is shared by Pooled and Personal category cards and monthly summaries: green below 50% spent, yellow at 50–79%, red from 80%. At 100% the label changes to Limit reached; above 100% it says Over budget and shows the exact overage. Unset budgets stay neutral and show spending plus a direct Set monthly limit prompt. Progress bars remain bounded while overage percentages stay visible. Categories needing attention appear first with stable ordering for equal status. An attention shortcut opens Budgets.

The pool has separate funding status computed from the month-end balance and that month's booked pooled spending, so category limits do not imply funds are available. Carry-in and contributions count as pool capacity. A deficit is red even if there is no new spending; an unfunded empty pool prompts Add pool funds. The widget uses the same funding thresholds and keeps its small layout compact. Receipt drafts are still excluded from spending. Colors are paired with text and icons, following [Apple's accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility). Yellow/red/green status text adapts to appearance; button controls become brighter in dark mode while filled primary actions retain a readable dark green background.

Other corrections: a receipt-only search result no longer shows a contradictory No matching expenses empty state. Tapping the month label returns to this month, with a visible hint for historical months. Budget editing focuses the amount immediately, supports a keyboard Done action, accepts decimal zero to clear a limit, avoids force-unwrapped input and reports failures in the active editor. Pool totals stack into readable label/value rows at accessibility text sizes.

Verified with production views in an isolated offline iPhone 17 / iOS 27 harness using synthetic expenses: red over/reached/near-limit categories, yellow spending, green spending, neutral unset limits, Pooled and Personal summaries, stable section header and scan footer, receipt-only search and one-tap month return. Dark appearance and accessibility2 text size were inspected, including the corrected pool totals and brighter controls. The harness has no Supabase configuration and a separate App Group. No household records were changed. Foundation checks total 83, including exact threshold boundaries, fractional percentages, large values, carry-in deficits and budget-input validation.

Remaining usability verification: real camera/receipt capture, small older iPhones and iPad split view, live VoiceOver traversal, real-device keyboard/autofill and multi-device sync still need physical tester checks. No full accessibility conformance is claimed.

## Receipt and recovery polish — build 6

Further review found slow access to the receipt photo, late suggestions not updating an already-open form, accidental dismissal of edits, and backup errors interrupting locally successful saves.

- Amount and merchant remain the first fields. Receipt photo is immediately below them, before source/category. Date is visible in a collapsed optional-details row; existing notes/names expand it automatically. Manual entry uses amount focus and a keyboard Next action to reach the merchant.
- Late receipt suggestions update untouched amount, merchant, date and category fields while preserving manual corrections. Background changes to booked expenses never autofill an editor.
- Receipt photos open from the editor's stable presentation point. The previous form-row presentation dismissed the editor on the QA simulator; the corrected viewer stays open, fits the complete photo initially and supports pinch/double-tap zoom. Closing it restores the editor and its values.
- Expense and budget forms protect unsaved edits with Discard / Keep editing actions and block accidental swipe dismissal. Entry deletion asks for confirmation and explains shared-room impact.
- Receipt loading exposes download retry and invalid-photo errors. Photo-library loading is cancellation-aware and allows selecting the same photo again. Save waits for attachment loading to finish; cancelling quick capture during loading warns before stopping.
- Background sync failures show Saved locally · backup pending with Retry. A details action explains the delay to other housemates. Local save failures still use a blocking error; sync success clears the notice. Room switching and authentication controls are disabled while their relevant operation runs.

Verified with production views in a separate, credential-free offline harness: delayed suggestions filled ₹472.50 and Test cafe; the nearby sample photo opened, fitted and double-tap zoomed; Done returned to the editor retaining its values. Editing the amount to ₹99 then cancelling showed the unsaved-changes warning and retaining the form preserved the correction. Simulated backup failure displayed an inline notice without an interrupting alert, and Retry cleared it. No household records were changed. Foundation checks total 89, including partial autofill, manual corrections, baseline updates and rejecting suggestions for booked entries. Debug build, signed Release archive and internal TestFlight export succeeded for version 1.0 build 6. The package has not been uploaded.

The Mac locked before the last UI check of the final alert-style Keep editing button and refreshed production sign-in gate. The preceding discard warning and retained ₹99 correction were inspected; the final alert is build-verified. The offline harness was removed and production build 6 was restored and launched on the QA simulator.

Physical camera, pinch gestures, older/smaller devices, iPad layout, VoiceOver and multi-device sync remain tester checks. These implementation checks do not claim complete accessibility or real-network failure coverage.

## Code and UX audit — 26 November 2026

Full review of every source file against Apple's Human Interface Guidelines (navigation, modality, feedback, accessibility) and Swift/SwiftUI practice (single source of truth, typed errors, no dead code).

Bugs fixed:

- Category suggestions stopped after the first auto-filled category: programmatic changes were recorded as a user choice. Only an explicit pick now locks the category, and the redundant "Use suggested category" button is gone.
- Choosing "Personal only" as the active room was silently reverted on every refresh/foreground. The option is removed (Personal is always its own tab); with several rooms the room title is a switcher menu.
- Settings export/restore errors went to a root alert hidden behind the Settings sheet, and a successful restore gave no feedback. Both now report in place; export is one tap through the Files exporter.
- Stale account errors resurfaced later as unrelated alerts (failed member refresh, failed join, sign-out). They are cleared when consumed.
- Currency showed `₹9,439.5`; amounts with paise now always show two decimals, including in editable fields.
- The amount field rejected the keypad's decimal comma in locales that use one.
- The legacy "Import existing local ledger" option appeared even when there was nothing to import.
- Widget said "1 receipts" and "0 receipts to review".
- Password recovery had no way to back out and no mismatch hint. Sign out had no confirmation and sat beside Delete account.
- Room name field disabled capitalization; version text was hard-coded.

Cleanup: removed the unreachable iCloud/CloudKit sync and sharing path (~150 lines; `sync()` returned before reaching it). Store saves throw typed errors instead of setting a shared alert string. Views.swift is split into EntryEditor, BudgetViews and SettingsView; shared colors and components (BrandMark, PrimaryButton, AmountField, card/inputField, messageAlert) live in DesignSystem.swift; money helpers in Money.swift are shared by the app, widget and tests. An AccentColor asset gives sheets and system controls the brand tint. Month queries no longer rebuild the calendar per entry, and ledger merges are linear.

UX: overview shows the three most urgent categories with See all instead of duplicating the Budgets tab; the redundant toolbar camera button is removed (the Scan receipt bar remains); a photo added in the editor fills only empty or untouched fields instead of offering two separate "use suggestion" buttons; camera denial in the editor offers a Settings button; members are managed from a per-person menu; the Expenses list shows a month total and attachment indicator; search also matches notes.

Verified on an iPhone 17 / iOS 27 simulator with a temporary offline harness (fake account, synthetic data, no Supabase connection; removed afterwards): Pooled overview, Expenses, receipt review editor, manual entry with merchant-based category suggestion and save, Personal tab in dark mode. Foundation checks total 96. Sign-in, room flows, camera capture and VoiceOver were not exercised in this pass.
