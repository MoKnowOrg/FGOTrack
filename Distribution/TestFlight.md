# FGOTrack internal TestFlight

Support and beta feedback: **business@knoworganization.com**. Privacy and internal-use information is accessible before sign-in and in Account Settings. This package targets internal beta testing, with no invented public policy URL.

## Build identity

- App: FGOTrack, version 1.0, build 4
- Bundle ID: com.fgotrack.house
- Widget: com.fgotrack.house.widget
- Team: 26JF64DL4B
- Shared widget container: group.com.fgotrack.house
- iOS 17+; Apple Intelligence receipt suggestions require an eligible device, iOS 26+ and an available model. Vision OCR and manual entry work independently.

## Prepared artifacts

`build/FGOTrack.xcarchive` contains the signed app and widget, icon, privacy manifests and debug symbols. `build/TestFlight/FGOTrack.ipa` is the App Store Connect export, signed with Cloud Managed Apple Distribution and configured for internal TestFlight only. Neither artifact has been uploaded.

The shared FGOTrack scheme archives Release. Rebuild after source changes:

```sh
xcodebuild -project FGOTrack.xcodeproj -scheme FGOTrack -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/FGOTrack.xcarchive archive
xcodebuild -exportArchive -archivePath build/FGOTrack.xcarchive \
  -exportOptionsPlist Distribution/ExportOptions.plist -exportPath build/TestFlight \
  -allowProvisioningUpdates
```

Open the archive in Xcode Organizer. Validate it, then Distribute App → App Store Connect → TestFlight Internal Only. Confirm the App Store Connect record uses the same bundle ID and support email. The IPA can also be uploaded with Apple's Transporter. Upload and tester invitations have not been performed.

[Apple's distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases) explains validation and upload. [Internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers) must be eligible App Store Connect users; housemates without these roles require external TestFlight testing instead. TestFlight builds expire after 90 days; arrange replacement builds for continued beta use.

## Server configuration before inviting testers

1. Migrations 001–004 are already applied to the supplied project. Do not blindly reapply them.
2. Approve and deploy `supabase/functions/delete-account` (prepared in the dashboard; deployment is pending user approval). It verifies the caller using Auth and keeps the service-role key entirely on Supabase. Instructions are in `supabase/README.md`.
3. Authentication → URL Configuration: allow `fgotrack://auth/callback`. This is used by confirmation, recovery and magic links. Configure reliable email delivery/SMTP and test confirmation with a real tester's email. Password sign-in was verified with a disposable confirmed QA account, without sending email.
4. Email signup is supported. Apple and Google appear only when configured; Google is offered alongside Apple. Provider credentials must be configured in Supabase, never in the app.
5. Perform a multi-device photo sync check and account deletion with a disposable tester before invitations. Database deletion logic is covered by rollback integration checks; the Edge endpoint also requires a live smoke test after deployment.

## Beta description

FGOTrack helps our Bengaluru hacker house track one shared pool and each person's private spending. Set category budgets, record contributions, and carry unused pooled funds forward monthly. Scan a receipt to save it immediately, then confirm suggested details later. Personal records stay private; pooled expenses, budgets and photos are shared only with room members.

## What to test

Create/confirm an account → create or join a room → add pool funds → save a receipt photo → review the suggested INR total → confirm the expense. Switch to Personal, set a private budget, and add a private expense. Confirm neither appears for a housemate. Check category warnings, offline save/sync, rollover, widget quick capture, password reset, ownership transfer and account deletion. Check Invite people → native sharing / QR → required sign-in → room preview → Join room. Confirm reopening sharing retains the invitation and replaced/expired links are rejected. App links currently require FGOTrack installed; HTTPS install/join links await a public domain.

## Privacy declarations

The included manifests declare no tracking. Account email/name/ID, financial records, receipt photos and notes are linked to the signed-in account for app functionality. The app uses UserDefaults for its own settings and widget data. OCR and optional model processing are on device. Supabase stores synced records and private receipt objects. No ad SDK, analytics SDK, location tracking or cloud LLM is included.

Deleting an expense hides its attachment but does not automatically purge superseded receipt objects. Account deletion removes private records/photos; shared records/photos remain for housemates with creator ownership cleared. Other devices can retain downloaded copies until their local cache is removed. Exported JSON contains references, not receipt image bytes.
