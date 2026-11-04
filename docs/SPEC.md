You are the founding engineer and product designer of TICK, my personal finance app for iPhone. Repo: this checkout (github.com/prithvisaran3/tick). I am Prithvi, the only user for now; we expand later.

################################################################
# 0. UNATTENDED OPERATION — READ FIRST
################################################################
0.1 I am NOT watching and will not answer. Never ask me a question, never ask for confirmation, never stop to offer options. When something is ambiguous, choose what best serves this spec, log the choice in docs/DECISIONS.md, and continue.
0.2 Do NOT end your turn until every phase in Section 9 is done and the Final Output (Section 10) is delivered, or you are genuinely out of budget. Finishing a phase is not a reason to stop: commit, update docs/NEXT.md, and immediately start the next phase. If a step is blocked (missing variable, a console-only click, an API that refuses), do everything that doesn't depend on it, record the exact manual step at the top of docs/NEXT.md, and keep going.
0.3 First actions, in order: (a) save this entire prompt verbatim as docs/SPEC.md; (b) write CLAUDE.md (stack, commands, conventions, design rules, file map, "how to resume"); (c) create docs/NEXT.md and docs/DECISIONS.md. Update NEXT.md at the end of EVERY phase so that if the session dies, a fresh session told "Read CLAUDE.md and docs/NEXT.md and continue" can resume with zero context.
0.4 Commit and push to main at the end of every phase (and after any large chunk of work) with a clear message.

################################################################
# 0B. MODEL ROUTING — BE EFFICIENT
################################################################
You (the main session) do the core engineering: architecture, data model, business logic, UI code, integrations, and judgment calls.
Delegate to subagents with the Agent/Task tool, choosing the model explicitly:
- model "haiku" for mechanical, well-specified, low-risk work: generating the 24-icon SVG set from a written spec, exporting icon sizes and splash, writing fixtures and seed data from a schema you give it, writing docs from an outline you give it (SHORTCUTS_SETUP.md, RUN_ON_MAC.md, README), running test suites and summarizing failures, renaming/formatting sweeps, writing boilerplate tests for already-designed functions, scanning for secrets.
- model "opus" ONLY for these three reviews, each with a fresh agent that did not write the work: (1) after P0, a design review of design/exports/*.png and the brand sheet against Section 7, returning a ranked list of fixes; (2) after P3, a correctness review of the dedupe/reconcile logic and its tests; (3) after P7, a final design + UX review of every golden screenshot against Section 7. Apply every fix you agree with; log disagreements in DECISIONS.md.
Rules for delegation: give each subagent a complete, self-contained brief (files to read, exact output paths, acceptance criteria), because it starts with no context. Run independent subagents in parallel and keep working while they run. Never delegate anything touching secrets, money math, RLS, Plaid token handling, or the dedupe algorithm itself to haiku. Don't re-read large files you just wrote. Don't regenerate unchanged assets.

################################################################
# 0C. ENVIRONMENT, VERIFICATION, SECRETS
################################################################
Environment: Linux sandbox, NO Xcode, NO iOS simulator. You cannot build or run iOS. You CAN run Flutter analyze/tests, render Flutter golden screenshots, run Python, run Playwright, and call Supabase/Railway/Plaid/Gemini APIs. Install what you need: Flutter stable (git clone), Supabase CLI, Railway CLI, Python 3.12, Playwright + Chromium.
Verification gates per phase: `flutter analyze` zero warnings; `flutter test` green; pytest green; SQL/RLS tests green; golden screenshots regenerated and visually reviewed by you against Section 7 (open the PNGs, critique, fix, re-render). Swift can't be compiled here: keep it small, idiomatic, commented, and list exact Xcode steps in docs/RUN_ON_MAC.md.
Secrets are environment variables: SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, SUPABASE_DB_PASSWORD, GOOGLE_OAUTH_WEB_CLIENT_ID, GOOGLE_OAUTH_WEB_CLIENT_SECRET, GOOGLE_OAUTH_IOS_CLIENT_ID, GEMINI_API_KEY, PLAID_CLIENT_ID, PLAID_SECRET, PLAID_SANDBOX_SECRET, PLAID_ENV, RAILWAY_TOKEN.
- Never write, print, echo, log or commit any secret value. Never pass secret values to subagents; tell them the variable NAME if they need one.
- The app receives only SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, GOOGLE_OAUTH_IOS_CLIENT_ID, GOOGLE_OAUTH_WEB_CLIENT_ID and the API base URL, via --dart-define (document the exact command in RUN_ON_MAC.md, reading values from my local .env).
- Commit .env.example with NAMES only. .gitignore covers .env*, *.pem, secrets/, *.key.
- Before every commit, run a secret scan on the staged diff (key patterns AND the literal env values) and abort on any match.
- If a variable is missing, skip only what depends on it and note it at the top of NEXT.md.
Read current docs before integrating anything (Supabase, supabase_flutter, Plaid, Railway, google-genai, Core Haptics, WidgetKit, App Intents). Never rely on memory for endpoint names, SDK signatures or model ids. If a doc contradicts this spec, follow the doc and log it.

################################################################
# 1. ABOUT ME (personalize everything)
################################################################
Prithvi. Arlington, VA. Timezone America/New_York. USD. Clinical Software Engineer II, remote.
Paycheck frequency, amount, rent, bills and subscriptions are NOT known yet: build a fast onboarding (and Settings) to enter paycheck (frequency + next date + amount), rent, recurring bills and subscriptions, savings goals.
Until I enter data, Demo mode shows a realistic seed for a remote software engineer in Arlington: rent, utilities, phone, internet, groceries, coffee, rideshare, flights, Claude/Cursor/Apple Developer/domain subscriptions, and a biweekly paycheck.
I'm building a startup called Unstash on the side. I can tag transactions "Business"; auto-suggest the tag for dev/SaaS merchants (AI/API providers, domains, hosting, developer accounts, design tools); show a Business spend total per month (for taxes later).
Sign-in: Google only for now (Sign in with Apple later). Morning summary 8:00 AM local; weekly review Sunday 7:00 PM.

################################################################
# 2. WHAT TICK IS
################################################################
One job: I open it every morning and in three seconds know (1) am I okay, (2) what I can safely spend until payday, (3) what's coming in, (4) what's going out, (5) the one thing I should do today.
Everything is captured automatically; manual entry is the fallback, never the plan.
Five money flows: SPENT, EARNED, INCOMING (paychecks, refunds, money owed to me), OUTGOING (bills, subscriptions), OWED (IOUs). Splitwise-style splitting is a later phase, but the data model supports it now.

################################################################
# 3. ARCHITECTURE (decided)
################################################################
Repo layout: app/ (Flutter), api/ (FastAPI), supabase/ (migrations, seed, tests), design/ (brand source of truth), tools/ (generators, contrast checker, AHAP compiler, secret scan), docs/.

APP: Flutter stable, Dart 3, Riverpod 2 + riverpod_generator, go_router, freezed + json_serializable, supabase_flutter (Auth, Postgres, Realtime, Storage).
- Sign-in: google_sign_in -> supabase signInWithIdToken (serverClientId = web client id, clientId = iOS client id; follow current docs for nonce handling).
- flutter_local_notifications for the morning summary, bill reminders and weekly review, all scheduled ON-DEVICE.
- local_auth (Face ID lock), home_widget, image_picker.
- A local snapshot cache so the app opens instantly and shows the last known state offline.
- Custom-painter charts. No visible Material look anywhere.

NATIVE SWIFT (ios/):
(a) TickHaptics Flutter plugin: Core Haptics AHAP player; API play(pattern, tier?), prepare(), setMode(full|subtle|off).
(b) WidgetKit extension: small, medium, lock-screen rectangular + inline, reading an App Group snapshot JSON.
(c) App Intent "Log expense" (amount, merchant, category) for Siri/Shortcuts/Action Button, opening quick-add prefilled via deep link.

BACKEND: Supabase (Postgres + RLS owner-only on every table, Realtime, Storage, Auth) + ONE Python 3.12 FastAPI service in api/ on Railway for ALL server logic: /ingest, Plaid, Gemini, scheduled jobs, webhooks, Ask Tick streaming (SSE).
- Every authenticated endpoint verifies the Supabase JWT.
- Scheduled jobs: pg_cron + pg_net calling FastAPI with a CRON_SECRET header (generate it yourself; set it in Railway env and Supabase Vault; never print it).
- Railway: `railway up` with RAILWAY_TOKEN; set service env vars; create a public domain; record the URL in NEXT.md. If the CLI can't do something with a project token, write the manual step at the top of NEXT.md and continue.

SUPABASE SETUP (CLI + Management API with SUPABASE_ACCESS_TOKEN):
- Link the project; all schema as migrations in supabase/migrations pushed with `supabase db push`.
- Enable the Google provider with the web client id/secret via PATCH /v1/projects/{ref}/config/auth.
- Allow-list the tick:// redirect.
- Create the private bucket "receipts" with RLS.
- Enable Realtime on transactions, expected, messages, connections.

BANKS (Plaid, free Trial plan, PLAID_ENV=production = real data, HARD CAP OF 10 ITEMS EVER; removing an Item does NOT free a slot):
- Behind a BankProvider interface.
- FastAPI /plaid/link-token creates a link token (products ["transactions"], country_codes ["US"], webhook = <railway url>/webhooks/plaid, OAuth redirect per current docs).
- The app opens Plaid Link (Hosted Link in ASWebAuthenticationSession, or the official SDK if current docs recommend it; decide from docs and log it).
- FastAPI exchanges public_token -> access_token, stored ONLY in Supabase Vault and referenced by id; never sent to the app or logged.
- NEVER create or remove production Items automatically or in tests. All automated tests use PLAID_SANDBOX_SECRET.
- Before linking, the UI shows "You have N of 10 bank links left" and requires Hold to confirm.
- /transactions/sync with a stored cursor: on connect, on SYNC_UPDATES_AVAILABLE, and every 6h as backstop. Handle added/modified/removed; reconcile pending -> posted via pending_transaction_id.
- Verify every webhook's Plaid-Verification JWT (keys from /webhook_verification_key/get, cached); reject stale ones.
- ITEM LOGIN_REQUIRED / ERROR: flag the connection, show a calm re-link banner, use Link update mode (never a new Item).

AI (Gemini via google-genai; model id = ONE config constant set to the current best "Flash" model per Google's docs), only in api/:
(1) parse messy alert text when regex fails;
(2) clean merchant names + categorize (learned rules win over AI);
(3) receipt photo extraction;
(4) Ask Tick chat with tool calling;
(5) the weekly insight text and the Morning Receipt advice line.
Send tool results, never full-history dumps. Log tokens per call to ai_usage. Timeouts + graceful fallbacks: the app never blocks on AI.

################################################################
# 4. CAPTURE PIPELINE
################################################################
Channels:
1. iOS Shortcuts "Message" automation (sender = my bank, Run Immediately) -> POST /ingest {source:"sms", text}.
2. Shortcuts "Transaction" (Wallet) automation for Apple Pay -> POST /ingest {source:"applepay", merchant, amount, card}.
3. Plaid sync.
4. Receipt photo -> Storage -> Gemini extraction.
5. Quick add: custom number pad, 3 taps max, plus one-line natural input ("uber 18", "got 40 from Alex", "rent 1850 on the 1st").

/ingest is source-agnostic. Auth via a per-user random token (generated in Settings, stored hashed, revocable) in header X-Tick-Token; rate-limited; raw payloads stored in ingest_logs.

Parsing:
- Table-driven regex parsers for Chase, Bank of America, Capital One, Amex, Wells Fargo, Citi, Discover and Apple Card alerts first; Gemini fallback second; each result gets a confidence score.
- Below 0.8 -> the Caught inbox, never silently into the ledger.
- Create tools/samples/ with a README asking me to paste real masked alerts.

Dedupe + reconcile (hardest logic, test it hardest): one purchase may arrive via SMS + Apple Pay + Plaid.
- Match on amount (exact, or within 25% tip tolerance for restaurants/rideshare), a 72h window, card last-4 when present, and fuzzy merchant similarity.
- Merge into ONE transaction keeping every source ref; Plaid posted wins as truth.
- Handle pending -> posted and tip adjustments; never double count.
- Property-based tests + fixtures for every channel combination.

Write docs/SHORTCUTS_SETUP.md: tap-by-tap steps for both automations, the exact ingest URL, where to paste the token, how to test it.

################################################################
# 5. DATA MODEL (Postgres; every row has user_id; RLS owner-only; RLS tests)
################################################################
Tables:
- profiles; settings (haptics full|subtle|off, sound, theme system|dark|light, notification times, payday rule, onboarding_done); ingest_tokens (hash)
- connections (provider, institution, status, vault_secret_id, cursor, last_synced_at); accounts; transactions
- categories (sensible defaults + icons); rules (merchant pattern -> category/tags, learned from corrections)
- budgets; goals; recurring (merchant, cadence, expected amount, next date, price history); expected (paycheck|refund|iou, amount, expected date, status, matched_transaction_id)
- people; insights; chats; messages; ingest_logs; snapshots (daily totals); ai_usage

transactions: id, user_id, amount_cents bigint (negative = out), currency, occurred_at, merchant_raw, merchant_clean, category_id, account_id, status pending|posted, sources jsonb, confidence, needs_review, tags text[], note, receipt_path, splits jsonb, participants jsonb (unused in v1 UI), created_at, updated_at. Index (user_id, occurred_at desc). All money math in integer cents.

################################################################
# 6. FEATURES (v1)
################################################################
TODAY: one hero number, "Safe to spend" until next payday = available cash - bills due before payday - planned goal contributions, revealed with the Count-up. Below it: today's captures as stickers, an Incoming strip (Sky), an Upcoming strip (Clay), exactly ONE nudge card. The first open of the day plays the Morning Receipt first.
MORNING RECEIPT: yesterday printed as a receipt on Paper. Lines tick in; total; safe-to-spend; one advice line; a "Ticked." stamp. Tear off to save/share an image. A stylized card, never a fake store receipt.
ACTIVITY: grouped by day with daily totals; search; filters (category, account, business, needs review); shared-element transition to detail; swipe to recategorize or tag Business.
CAUGHT: low-confidence captures as a card stack. Right = looks right, left = fix it, up = Business; each direction has its own haptic.
FLOWS: month in vs out, category breakdown, vs last month, a calendar heatmap, Business total.
INCOMING & UPCOMING: predicted paydays, refunds, money owed to me, detected recurring bills/subscriptions, price-hike detection, a reminder the day before a bill. Arrived money triggers Landed.
BUDGETS & GOALS: light category caps with a pace line; goals with progress; a Payday plan on payday.
ASK TICK: SSE streaming chat with tools: query_transactions, spend_by_category, compare_periods, list_upcoming, list_incoming, get_balances, get_budgets, find_subscriptions, business_total. Inline mini charts, tappable transactions, suggested questions; answers lead with the number.
NUDGES (max one a day unless urgent): overspend pace, duplicate/unusual charges, forgotten subscriptions, bill due tomorrow, payday plan. Scheduled as local notifications.
SETTINGS: Face ID lock + privacy blur, haptics Full/Subtle/Off, sound, theme, bank connections (N of 10 used), ingest token + Shortcuts guide, categories and rules, CSV export, delete all data (Hold to confirm), demo mode.
WIDGETS + APP INTENT as in Section 3.
Not in v1: splitting UI, Android, investments, server push (the APNs plan goes in NEXT.md).

################################################################
# 7. DESIGN SYSTEM — the full Unstash brand system adapted for money. Follow exactly.
################################################################
7.1 Personality. Tick talks like the friend who's great with money: quick, warm, a little cheeky, always on my side, and calm whenever money looks wrong.
Brand test for every screen: "Would I screenshot this and send it to a friend without being asked?"
The look: night mode meets receipt paper. A deep ink canvas, one electric volt color, chunky friendly type, round stickers that slap onto things.

7.2 Constants (never change)
- Logo: a lowercase "tick" wordmark in a heavy rounded grotesk (Cabinet Grotesk Extrabold).
- App icon: an Ink rounded square with a Volt checkmark whose short stroke ends in a round dot (sibling of Unstash's box + volt dot).
- The name is "Tick" in sentences; the logo is always lowercase; never "TICK".
- Ink and Volt always appear together.
- One display face, one text face, one number face.
- The sticker: hero amounts and new captures sit on a round Volt sticker tilted 2-3 degrees, like a price tag.
- Motion: things pop out with a spring and a little overshoot.

7.3 Color (dark default; light follows system or setting)
- Ink #0E0E12: background, and text in light mode. Not pure black; the blue tint softens glow.
- Volt #C8FF2E: money in, safe-to-spend, primary actions, logo dot (16.3:1 on Ink).
- Paper #F5F3EC: light background and the Morning Receipt; warm, like receipt paper.
- Graphite #5B5B66: secondary text on Paper (6.0:1).
- Clay #FF6B4A: outgoing, bills, overspend (6.8:1 on Ink).
- Sky #7AA7FF: incoming/expected (8.1:1 on Ink).
Derive and verify: a dark secondary-text grey on Ink (≥4.5:1), dark surfaces (Ink lifted ~4% and ~8%), hairlines, light surfaces.
Rules:
- Volt is a FILL, never text on Paper (1.06:1); text on Volt is always Ink.
- Volt covers about 10% of any screen, so it always means "money or go."
- Three accents, one job each. Errors use Clay with calm copy, never alarm red.
- tools/contrast_check.py verifies every pair in tokens.json (4.5:1 body, 3:1 large) and fails CI on a miss.

7.4 Type
- Display (hero numbers, headlines, receipt total, wordmark): Cabinet Grotesk.
- Text: Satoshi.
- Numbers: Geist Mono with tabular figures.
- Fonts live in assets/fonts/. If missing, fall back to Bricolage Grotesque (OFL, google_fonts) + Geist Mono or JetBrains Mono, log it, and list the missing files in NEXT.md. Never Inter/SF/Roboto.
- Define a full type scale in tokens.json.

7.5 Shape and layout
- Radius 24 on cards, 999 on buttons/chips/stickers; nothing sharp.
- ONE hero number or hero element per screen. 8-pt grid, generous spacing.
- List amounts in plain Geist Mono (Volt for money in, default text for out, Clay only for alerts). Stickers are reserved for hero amounts and new captures.
- Merchant avatars are monogram stickers on category-tinted circles.
- No stock photos, no AI renders, no icon packs: one custom 24-icon outline set (1.75px stroke, rounded caps) as SVG in design/icons.

7.6 Motion (design/motion.json is the source of truth)
- Springs with a small overshoot everywhere; nothing eases in and out like a slideshow.
- Start values: standard (stiffness 380, damping 28, mass 1); pop (520, 18); sheet (300, 30).
- Captures pop up from the bottom edge. Stickers slap on with a 2-3 degree tilt and a tiny bounce. The "Landed" and "Ticked." stamps slam from scale 1.15 to 1.0. The hero number counts up.
- Shared-element transitions from rows to detail.
- Reduce Motion -> 150 ms fades.
- 120 Hz smooth: const widgets, RepaintBoundary on animated pieces, precached fonts/images. Skeletons, never spinners.

7.7 Haptic language (8 patterns, one meaning each; defined once in design/haptics.json, compiled to AHAP by tools/compile_ahap.py, played through one Dart API)
1 THE POP (haptic logo): app launch / first open of the day. ~300 ms: transient 0.6 / sharpness 0.9, then transient 0.9 / sharpness 0.2 at +120 ms.
2 PRICE WEIGHT: a sticker amount landing. Under $20 = 0.4 / 0.7; under $100 = 0.7 / 0.45; $100+ = 1.0 / 0.2.
3 COUNT-UP: ticks speeding from a 90 ms to a 30 ms interval and sharpening as the number rises, ending in one solid hit.
4 HOLD TO CONFIRM: delete, mark paid, link bank, delete all data. A continuous ramp from 0.1 to 0.8 over ~600 ms, then a click on release; releasing early cancels softly.
5 SORT BY FEEL: Caught swipes. Right = two light quick ticks; left = one soft low tap; up = a rising two-step.
6 LANDED: a heavy stamp (1.0 / 0.3) with a ~150 ms fading tail, synced to the stamp animation and the chime.
7 RECEIPT TEAR: a 0.25 tick per receipt line, then a rip (~8 randomized transients over 180 ms) when torn off to share.
8 HEARTBEAT: reserved for future settle-ups, one soft beat per person; gallery only.
Rules:
- One pattern, one meaning; each fires on the same frame as its animation and sound.
- Modes: Full / Subtle (x0.5 intensity, no continuous events) / Off. Low Power Mode forces Subtle. Core Haptics already respects the system switch.
- Errors use the standard system warning; custom patterns are only for good moments.
- The app works perfectly with haptics off. Call prepare() before predictable moments.
Sound: synthesize two .caf files under 300 ms each (a capture pop and a two-note Landed chime). Use an ambient audio session so the silent switch mutes them. Sound is on by default.

7.8 Voice and copy
Rules:
- Lead with the number or the action. Sentence case everywhere.
- Button verbs: Add, Tick, Link bank, Fix, Move to savings.
- Never say "users", "platform" or "leverage".
- Humor is OFF for errors, security, bank problems and anything wrong with money. A wink is fine in empty states and success moments; no memes, no emoji spam, no dated slang.
- Branded terms, max six: Safe to spend, Morning Receipt, Caught, Landed, Payday plan, Ask Tick. Everything else uses plain words.
Tone samples:
- "Good morning. $214 safe to spend until Friday."
- "Caught: $18.40 at Uber."
- "Landed. $2,310 from payroll."
- "Payday. Move $400 to savings and you still have $1,120 safe."
- "Food is running hot: on pace for $520 vs your $400."
- "Quiet day. Your wallet says thanks."
- "That didn't go through. Try again, nothing was lost."
- "Your Chase link needs a quick sign-in to keep syncing."

7.9 Five signature moments (highest polish; everything else stays quiet and fast)
1. The Safe-to-spend reveal (count-up landing on a Volt sticker).
2. The Morning Receipt (prints with ticks, "Ticked." stamp, tear to share).
3. Caught (a capture pops up as a sticker with Price weight + the pop sound).
4. Sort by feel (the Caught card stack).
5. Landed (stamp + heavy haptic + chime).

################################################################
# 8. DESIGN FILES FIRST (before any screen code)
################################################################
Create design/:
- tokens.json -> tools generates app/lib/design/tokens.g.dart (never hand-edit generated tokens).
- haptics.json, motion.json, copy.md.
- brand-sheet.html (logo, icon, colors with contrast ratios, type specimens, sticker, motion, haptic table, voice).
- icons/ (24 SVGs) and logo/ (wordmark + icon SVG, the full iOS icon set, a splash).
- mockups/: high-fidelity HTML/CSS at 393x852 for Today, Morning Receipt, Activity, Caught, Ask Tick, Flows, Incoming & Upcoming, Settings, and Onboarding (3 steps), in dark and light. Render to design/exports/*.png with Playwright.
Self-critique each mockup against Section 7 and iterate at least once, then run the Opus design review (0B).
In the app: a debug-only /dev/gallery route showing every token, component, sticker and motion, plus a button per haptic.
Flutter screens must match the mockups. Golden tests render each screen (dark + light, demo data) to app/test/goldens/; compare them against design/exports/ and fix drift.

################################################################
# 9. PHASES (run all, in order, without stopping)
################################################################
P0 FOUNDATIONS:
- Repo layout, CLAUDE.md, .env.example, secret scan.
- GitHub Actions: analyze, tests, pytest, contrast check.
- All Section 8 design files + Opus design review + fixes.
- Tokens generated, theme, fonts.
- TickHaptics plugin + AHAP compiler + sounds.
- Supabase linked with first migration + Google provider + receipts bucket.
- FastAPI /health deployed to Railway.
P1 SHELL: Google sign-in, Face ID lock + privacy blur, custom bottom bar/navigation/sheets/number pad, gallery, icon + splash, onboarding.
P2 LEDGER: full schema + RLS + RLS tests, categories seed, quick add + natural input, Activity, Today with unit-tested math, Demo mode seed, goldens.
P3 CAPTURE: /ingest, tokens, parsers + Gemini fallback, dedupe/reconcile with exhaustive tests, Opus correctness review + fixes, Caught inbox, SHORTCUTS_SETUP.md.
P4 BANKS: Plaid link token, Link flow, token exchange into Vault, /transactions/sync, webhook verification, 6h backstop, balances, re-link flow, "N of 10 links" counter.
P5 INTELLIGENCE: categorization + learned rules, recurring detection + price hikes, incoming prediction + Landed matching, safe-to-spend, nudges, local notifications, Morning Receipt + share image, Payday plan, Flows.
P6 ASK TICK: SSE chat with tools, mini charts, tappable transactions, suggested questions, ai_usage logging.
P7 NATIVE + POLISH:
- Widgets, App Intent, receipt scanning.
- Motion timing audit, haptic sync audit.
- Accessibility: Dynamic Type to XXL, VoiceOver labels, contrast.
- Performance pass; every empty/error/loading state written.
- Final Opus design + UX review of all goldens, with fixes.
P8 HANDOFF:
- README.
- docs/RUN_ON_MAC.md: exact Xcode steps (signing, capabilities, App Group, widget + intent targets, URL scheme) and the full flutter run command with --dart-define values read from my local .env.
- docs/SHORTCUTS_SETUP.md, DECISIONS.md.
- NEXT.md with: manual steps left, the Splitwise plan (people, groups, splits, settle-up, Heartbeat), the APNs push plan, Sign in with Apple, and the path to opening Tick to others.

################################################################
# 10. FINAL OUTPUT (deliver before ending your turn)
################################################################
1. Write docs/FINAL_REPORT.md:
   - What was built, phase by phase, with status (done / partial / blocked + why).
   - Links to every golden screenshot and design export.
   - The deployed API URL; what's deployed on Supabase and Railway.
   - Test counts and results.
   - A numbered "Your 15 minutes" checklist of everything I must do by hand to run Tick on my iPhone today, in order.
   - Known gaps and recommended next steps.
2. Final commit + push.
3. End with a short message: the 5 most important things built, the "Your 15 minutes" checklist, and anything that failed.

Begin now with 0.3, then P0.
