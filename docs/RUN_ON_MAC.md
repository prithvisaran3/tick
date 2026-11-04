# Run Tick on your iPhone: a step-by-step guide for a first-timer

Plan for about 45 minutes the first time (the downloads are the slow part). You need a Mac, an iPhone, a cable and a free Apple ID (a paid developer account is NOT needed). Nothing here was compiled in the build sandbox (no Xcode), so the Swift files are written but not yet run on a device; see "What to check" in `docs/NEXT.md`.

Words you will see:
- **Terminal**: the app on your Mac where you type commands (Cmd+Space, type "Terminal", Enter).
- **Xcode**: Apple's app builder. Free from the Mac App Store.
- **Repo**: the Tick code folder.

## Step 1. Install the tools (one time)
1. Install **Xcode** from the Mac App Store. Open it once and accept the license. Then in Terminal:
   ```bash
   xcode-select --install
   sudo xcodebuild -license accept
   ```
2. Install **Homebrew** from https://brew.sh (paste the one line it shows).
3. Install Flutter, CocoaPods and Python:
   ```bash
   brew install --cask flutter
   brew install cocoapods python
   flutter --version
   flutter doctor
   ```
   Tick needs **Flutter 3.44 or newer** (it prints "Dart 3.12" or higher). If `flutter --version` shows something older, run `brew upgrade --cask flutter`. In `flutter doctor` only the **Xcode** and **Flutter** lines need a green tick.
4. On your iPhone: Settings > Privacy and Security > **Developer Mode** > on, then restart the phone.

## Step 2. Get the code
```bash
cd ~/Documents
git clone https://github.com/prithvisaran3/tick.git
cd tick
git checkout main
```

## Step 3. Your private settings file
```bash
cp .env.example .env
open -e .env
```
Fill in only these two lines (values are in your Supabase dashboard > Project Settings > API), save, close:
```
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
```
`.env` is private and never uploaded. The other secrets live on the server; do not put them on your Mac.

## Step 4. Get your run command
```bash
python3 tools/setup_local.py
```
It prints a command that starts with `cd app && flutter run`. Copy it into a note.

## Step 5. Open the project in Xcode and set signing
```bash
cd app && flutter pub get && cd ios && pod install && open Runner.xcworkspace
```
In Xcode: click **Runner** (blue icon, top of the left list) > the **Runner** target > **Signing & Capabilities** > tick **Automatically manage signing** > choose your **Team** (your Apple ID; add it under Xcode > Settings > Accounts if missing).
If Xcode says the bundle identifier is taken, change `com.prithvi.tick` to something unique like `com.yourname.tick`. Tick works with any bundle id. **Do not add any capability** (no App Groups): a free Apple account cannot use them, and Tick does not need them.

## Step 6. Run on the phone
1. Plug in the iPhone, unlock it, tap **Trust** if asked.
2. Paste the command from Step 4 into Terminal and press Enter. Pick your iPhone if asked.
3. First time only, on the iPhone: Settings > General > VPN and Device Management > your Apple ID > **Trust**, then run the command again.
4. Tick opens. Tap **Continue with Google**. A sign-in sheet opens, you choose your Google account, and it returns to Tick. Then enter when you get paid and your take-home.

**Sign-in needs these server-side settings (already done for you; check them if sign-in fails):**
- Supabase > Authentication > Providers > Google is on, with your Google **web** client id and secret.
- Supabase > Authentication > URL Configuration > Redirect URLs includes `tick://login-callback`.
- Google Cloud > Credentials > your **web** OAuth client > Authorized redirect URIs includes `https://<your-project-ref>.supabase.co/auth/v1/callback`.

## Step 7. Check it feels fast (important)
Debug mode is slow on purpose. To judge smoothness run the same command with `--release` (or `--profile`), for example:
```bash
cd app && flutter run --release --dart-define=...(the same three values)
```
Scrolling Activity and switching tabs should be smooth at 60 to 120 fps. Add `--dart-define=TICK_PERF=true` (in `--profile`) to see Flutter's performance bars.

## Step 8. Siri, Shortcuts and the Action Button (optional)
Open the **Shortcuts** app > search "Log expense" (Tick). Run it: it opens Tick with the add screen filled in. To bind it to the Action Button: Settings > Action Button > Shortcut > pick it.

## Step 9. Capture from bank texts and Apple Pay
Follow `docs/SHORTCUTS_SETUP.md`. In Tick: Settings > **Capture token** > **Make new token**, copy it (shown once).

## Step 10. Link your first bank (only once, carefully)
You only have **10 bank links for life** on the free Plaid plan. Removing a link does not give a slot back.
1. Settings > **Banks**. It shows "You have N of 10 bank links left."
2. **Hold** the Link bank button until it clicks. A Plaid page opens inside the app. Choose your bank and sign in (banks like Chase hand you to the bank's own login and back).
3. When it closes, Tick pulls your last 12 months in the background; rows appear over the next minute. Do this for ONE bank first. If it fails, read `docs/NEXT.md` before trying again.
4. If a link later says it needs a quick sign-in, tap **Fix** on the Banks screen (it re-uses the same slot).

## The home-screen widget (needs a paid Apple Developer account)
Widgets need the App Groups capability, which a free Apple account does not offer. So the widget is **not part of the build** and the app does not write widget data unless you start it with `--dart-define=TICK_WIDGETS=true`. With a paid account: File > New > Target > Widget Extension "TickWidget", replace its Swift file with `app/ios/TickWidget/TickWidget.swift`, set iOS 17, add App Groups `group.com.prithvi.tick` to BOTH Runner and TickWidget, and run with the define above.

## If something goes wrong
- **`flutter pub get` says the Dart SDK is too old**: upgrade Flutter (Step 1.3). Tick supports Dart 3.12 and newer.
- **"No such module" or pod errors**: `cd app/ios && pod repo update && pod install`.
- **Signing errors**: redo Step 5 with a unique bundle id.
- **Google sign-in shows an error or nothing happens**: you may be offline, or one of the three server settings above is missing. The error message on screen says which kind of failure it was; tap **Try again**.
- **Plaid link says unavailable**: open https://tick-api-production.up.railway.app/health in a browser; it should show `"ok":true`.
- **No haptics**: only on a real iPhone, and Settings > Haptics must not be Off.
- **App feels slow**: you are in debug mode. Use `--release` (Step 7).
