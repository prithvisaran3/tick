# Run Tick on your iPhone (from a Mac)

Everything below needs a Mac with Xcode. Nothing here was compiled in the build sandbox (no Xcode), so the Swift files (haptics plugin, widget, App Intent) are untested on a device. Budget about 15 minutes.

## 0. Prerequisites
- Xcode 16 or newer, signed in with your Apple ID (Xcode > Settings > Accounts).
- Flutter stable (`brew install --cask flutter`), then `flutter doctor`.
- Python 3 (for one helper script).
- Your iPhone on a cable, Developer Mode on (Settings > Privacy and Security > Developer Mode).

## 1. Get the code and your local `.env`
```bash
git clone https://github.com/prithvisaran3/tick.git && cd tick
git checkout claude/gifted-cannon-lkg2x3
cp .env.example .env
```
Open `.env` and fill the values you already have (the same names live in your password manager and in the Railway/Supabase dashboards). `.env` is git-ignored. The app only needs these four plus the API URL:
`SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `GOOGLE_OAUTH_IOS_CLIENT_ID`, `GOOGLE_OAUTH_WEB_CLIENT_ID`.

## 2. Generate the run command and the Google URL scheme
```bash
python3 tools/setup_local.py
```
It writes `app/ios/Flutter/Local.xcconfig` (the reversed Google client id, git-ignored) and prints the exact `flutter run` command with `--dart-define` values read from your `.env`. Copy that command; you will use it in step 5. It looks like:
```bash
cd app && flutter run \
  --dart-define=SUPABASE_URL=... \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
  --dart-define=GOOGLE_OAUTH_IOS_CLIENT_ID=... \
  --dart-define=GOOGLE_OAUTH_WEB_CLIENT_ID=... \
  --dart-define=API_BASE_URL=https://tick-api-production.up.railway.app
```

## 3. Xcode: signing, capabilities, App Group
```bash
cd app && flutter pub get && cd ios && pod install && open Runner.xcworkspace
```
1. Select the **Runner** target > Signing & Capabilities > pick your Team. Keep bundle id `com.prithvi.tick` (or change it, then see the Google note below).
2. Click **+ Capability** > **App Groups** > add `group.com.prithvi.tick`.
3. `TickHaptics.swift` and `LogExpenseIntent.swift` are already in the Runner target. Info.plist already has the `tick://` URL scheme, Face ID, camera and photo strings, and the Google reversed-client-id scheme (filled from `Local.xcconfig`).
4. Google Sign-In: in Google Cloud Console, the **iOS OAuth client** must use the same bundle id as Runner. If you changed it, update the client there.

## 4. Add the widget extension (about 3 minutes)
1. File > New > Target > **Widget Extension**. Name it `TickWidget`. Untick "Include Live Activity" and "Include Configuration App Intent". Finish, and "Activate" the scheme if asked.
2. Delete the generated `TickWidget.swift` (and any `TickWidgetBundle.swift`) from the new target, then drag `app/ios/TickWidget/TickWidget.swift` from this repo into the target (check "Copy items if needed" off; target membership = TickWidget only).
3. Set the TickWidget deployment target to iOS 17.0 (the file uses `containerBackground`).
4. TickWidget target > Signing & Capabilities > **+ Capability** > **App Groups** > `group.com.prithvi.tick` (same group as Runner).
5. Build once. Long-press the Home Screen, add **Safe to spend**. It fills in after you open the app once.

## 5. Run on the phone
Pick your iPhone as the device and run the command from step 2 (or press Run in Xcode after setting the dart-defines in the scheme). First launch: sign in with Google, then the three-step onboarding. Allow notifications when asked.

## 6. App Intent (Siri, Shortcuts, Action Button)
After one run, open Shortcuts > search "Log expense" (Tick) > run it, or set it as the Action Button action (Settings > Action Button > Shortcut). It opens Tick with quick add prefilled.

## 7. Capture from texts and Apple Pay
Follow `docs/SHORTCUTS_SETUP.md`. The token comes from Settings > Capture token in the app.

## Troubleshooting
- Google sign-in does nothing: the iOS client bundle id does not match, or `Local.xcconfig` was not generated (rerun step 2, then Product > Clean Build Folder).
- "Hold to link a bank" errors: check `https://tick-api-production.up.railway.app/health`; the Plaid link needs the API up.
- Haptics are silent in the simulator: expected. Use a real iPhone.
- Fonts look wrong: they are bundled (`app/assets/fonts`); do a full rebuild, not hot reload.
