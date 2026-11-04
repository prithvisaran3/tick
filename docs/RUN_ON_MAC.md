# Run Tick on your iPhone: a step-by-step guide for a first-timer

Plan for about 45 minutes the first time (the downloads are the slow part). You need a Mac, an iPhone, a cable, and a free Apple ID. Nothing here was compiled in the build sandbox (no Xcode), so the Swift files (haptics, widget, Siri action) are written but never tested on a device. If something does not work, see "If something goes wrong" at the bottom.

Words you will see:
- **Terminal**: the app on your Mac where you type commands (press Cmd+Space, type "Terminal", press Enter).
- **Xcode**: Apple's app builder. Free from the Mac App Store.
- **Repo**: the Tick code folder.

## Step 1. Install the tools (one time)
1. Install **Xcode** from the Mac App Store. Open it once and accept the license. Then in Terminal run:
   ```bash
   xcode-select --install
   sudo xcodebuild -license accept
   ```
2. Install **Homebrew** (a tool installer) if you do not have it: go to https://brew.sh and paste the one line it shows into Terminal.
3. Install Flutter, CocoaPods and Python:
   ```bash
   brew install --cask flutter
   brew install cocoapods python
   flutter doctor
   ```
   `flutter doctor` lists what is missing. You only need the **Xcode** and **Flutter** lines to be green. (Android lines can stay red.)
4. On your iPhone: Settings > Privacy and Security > **Developer Mode** > turn on, then restart the phone.

## Step 2. Get the code
```bash
cd ~/Documents
git clone https://github.com/prithvisaran3/tick.git
cd tick
git checkout main
```
(If `main` does not have the latest work yet, use `git checkout claude/gifted-cannon-lkg2x3` instead.)

## Step 3. Make your private settings file
```bash
cp .env.example .env
open -e .env
```
A text editor opens. Fill in only these lines (paste the values from your password manager or the Supabase and Google Cloud dashboards), then save and close:
```
SUPABASE_URL=
SUPABASE_PUBLISHABLE_KEY=
GOOGLE_OAUTH_IOS_CLIENT_ID=
GOOGLE_OAUTH_WEB_CLIENT_ID=
```
`.env` is private and never uploaded. Do NOT put the other secrets on your Mac; they live on the server already.

## Step 4. Generate the run command
```bash
python3 tools/setup_local.py
```
It creates a small hidden config file for Google sign-in and prints a command that starts with `cd app && flutter run`. **Copy that whole command** into a note; you will paste it in Step 7.

## Step 5. Open the project in Xcode and set signing
```bash
cd app && flutter pub get && cd ios && pod install
open Runner.xcworkspace
```
In Xcode:
1. Click **Runner** (blue icon, top of the left list) > the **Runner** target > **Signing & Capabilities**.
2. Tick **Automatically manage signing** and choose your **Team** (your Apple ID; add it under Xcode > Settings > Accounts if it is missing).
3. Click **+ Capability** > **App Groups** > **+** > type `group.com.prithvi.tick` > OK.
4. Leave the Bundle Identifier as `com.prithvi.tick`. If Xcode says it is taken, change it to something unique like `com.yourname.tick`, and remember it for the next step.

## Step 6. Check the Google sign-in client matches
Google Cloud Console > APIs and Services > Credentials > your **iOS** OAuth client. Its **Bundle ID** must be exactly the one in Step 5. If you changed it, edit it here.

## Step 7. Run on your iPhone
1. Plug in the iPhone, unlock it, tap **Trust** if asked.
2. In Terminal, paste the command from Step 4 and press Enter. Flutter picks your iPhone (choose it if asked).
3. First time only, on the iPhone: Settings > General > VPN and Device Management > your Apple ID > **Trust**. Then run the command again.
4. Tick opens. Tap **Continue with Google**, sign in, enter when you get paid and your take-home, then the big stuff. Allow notifications when asked.

## Step 8. The widget (optional, 3 minutes)
In Xcode: File > New > Target > **Widget Extension**. Name it `TickWidget`. Untick both "Include" boxes. Finish.
1. In the left list, delete the generated `TickWidget.swift` (Move to Trash). Right-click the **TickWidget** folder > **Add Files** > pick `app/ios/TickWidget/TickWidget.swift` > Target: **TickWidget** only.
2. TickWidget target > General > Minimum Deployments **iOS 17.0**.
3. TickWidget target > Signing & Capabilities > **+ Capability** > **App Groups** > `group.com.prithvi.tick`.
4. Run the app again, open it once, then long-press the Home Screen > **+** > search Tick > add **Safe to spend**.

## Step 9. Siri, Shortcuts and the Action Button (optional)
Open the **Shortcuts** app > search "Log expense" (Tick). Run it; it opens Tick with the add screen filled in. To bind it to the Action Button: Settings > Action Button > Shortcut > pick it.

## Step 10. Capture from bank texts and Apple Pay
Follow `docs/SHORTCUTS_SETUP.md`. In Tick: Settings > **Capture token** > **Make new token**, copy it (shown once).

## Step 11. Link your first bank (only once, carefully)
You only have **10 bank links for life** on the free Plaid plan. Removing a link does not give a slot back. So:
1. Settings > **Banks**. It shows "You have N of 10 bank links left."
2. **Hold** the Link bank button until it clicks. A Plaid page opens inside the app. Choose your bank and sign in. For banks like Chase it hands you to the bank's own login and back.
3. When it closes, Tick pulls your last 12 months. Do this for ONE bank first. Do not retry repeatedly; if it fails, read `docs/NEXT.md` before trying again.
4. If a link later says it needs a quick sign-in, tap **Fix** on the Banks screen. That re-uses the same slot.

## If something goes wrong
- **"No such module" or pod errors**: run `cd app/ios && pod repo update && pod install`.
- **Signing errors**: redo Step 5 with a unique bundle id.
- **Google sign-in does nothing**: Step 6 mismatch, or you skipped Step 4. Rerun Step 4, then in Xcode choose Product > Clean Build Folder and run again.
- **Plaid link says unavailable**: open https://tick-api-production.up.railway.app/health in a browser; it should show `"ok":true`.
- **No haptics**: they only work on a real iPhone, and Settings > Haptics must not be Off.
- **Fonts or colors look off**: stop the app and run the command again (do not use hot reload).
