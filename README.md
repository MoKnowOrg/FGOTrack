# FGOTrack

A native iOS expense tracker for a shared Bengaluru hacker house pool and private personal expenses. Sign-up/sign-in is required. The bottom tabs are Pooled and Personal, each with expenses, receipt drafts and category budgets. Unused pooled funds carry forward monthly; category limits continue until changed.

Quick capture opens the camera and saves the photo immediately. Free on-device Vision OCR and optional Apple Foundation Models suggest details; review and confirm before spending is booked. Supabase Auth, database access controls and a private receipt bucket provide account and room backup. The pool widget opens quick capture or manual entry.

Support: business@knoworganization.com. Privacy information is available inside the app before sign-in and in Account Settings.

- [Internal TestFlight package and release steps](Distribution/TestFlight.md)
- [Usability review](Distribution/Usability.md)
- [Logo and generation prompt](Distribution/Branding.md)
- [Supabase deployment](supabase/README.md)

## Validation

`Tests/run.sh`: accounting, INR parsing, receipt drafts, OCR/model validation and separate personal budgets. `Tests/test_supabase.py`: rollback-only access control and account lifecycle checks using a private external connection file. `Tests/run-ai.sh`: real Foundation Models smoke test on an eligible Mac.

The Xcode project has a shared FGOTrack scheme, AppIcon, privacy manifests and an embedded widget. Developer team 26JF64DL4B and existing bundle/App Group identifiers are preserved. Release artifacts are ignored by Git under `build/`.

