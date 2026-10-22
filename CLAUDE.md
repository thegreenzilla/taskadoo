# Taskadoo – project brief for Claude Code

## What this is
Taskadoo: on-demand flat-pack furniture assembly (Philippines) – customer site, assembler app, dispatcher,
enterprise portal, admin. The real system is at `staging/app/` (Supabase); the landing page and `staging/demo/` are design prototypes.
Owner: Dennis (non-technical). Explain changes in plain language, one step at a time, confirm before big changes.

## Live setup
- GitHub Pages from repo `thegreenzilla/taskadoo`, branch `main`, folder `/ (root)`.
  Domain later: **taskadoo.asia** (main) with taskadoo.ph forwarding to it; staging will be `taskadoo.asia/staging/`.
- **Staging** (try changes here first): `staging/` → https://thegreenzilla.github.io/taskadoo/staging/
  - `staging/index.html` – customer landing page = Dennis's design export, built with
    `python3 originals/build.py originals/Taskadoo_Landing-3.html staging/index.html "Taskadoo" 1 originals/landing-links.js`
    (landing-links.js sends its buttons to the app: Book now/Browse → `app/#/book` or `#/shop/<category>`, Log in → `#/login`,
    For business → `#/signup/enterprise`, Become an assembler → `#/signup/assembler`, receipt buttons → `#/receipt`).
  - `staging/app/` – **the real system** (Phase 1): `index.html` (vanilla JS, no build step), `config.js`
    (staging Supabase URL + publishable key, `STAGING:true`), `manifest.webmanifest`, `img/`
  - `staging/assembler/` – the assembler app link: redirects to `app/?app=asm#/tasks` (`window.ASM_APP`: own manifest
    `manifest-assembler.webmanifest`, sign-up starts as assembler). Assemblers always get the phone layout `renderAsm()` (design Apps-2).
  - `staging/staff/` – staff portal (Admin, Dispatcher, Evaluator): redirects to `app/?app=staff`; sign-in only. Hidden link = the
    "© 2026 Taskadoo" line in the website footer (landing-links.js + renderSite). `window.APP_MODE` asm|staff|cust; each app has its own
    Supabase session (`storageKey tk-auth-<mode>`); `homeApp(profile)` + `renderWrongApp()` send people to the right app.
  - `staging/demo/index.html` – the original clickable apps design, kept as the reference for later phases
  - Staging pages carry `noindex` and a red STAGING badge.
- **Production**: repo root → https://thegreenzilla.github.io/taskadoo/ – "Coming soon" placeholder for now.
  Going live = copy staging files to the root with a production `config.js` (separate Supabase project `taskadoo`).
- Workflow: change staging → Dennis tries it → copy the same change to production.

## Backend (Supabase)
- Staging project `taskadoo-staging`, ref `khxlothqjbjcfdcgkzcd` (Singapore). "Automatically expose new tables" is OFF
  and automatic RLS is ON → every table needs explicit `grant`s and policies.
- SQL lives in `supabase/sql/` as dated, idempotent files; Dennis pastes them into SQL Editor. A new database = run all files in date order.
- `supabase/test-data/` (staging only, NOT part of the date-order run): `add_test_data.sql` (Dennis replaces TYPE-A-PASSWORD; accounts
  `*@test.taskadoo.ph`, bookings with notes `[TEST]…`, eval times 14 days) and `remove_test_data.sql`.
- Tables: `profiles` (role: customer, assembler, dispatcher, enterprise, admin; `requested_role` from sign-up waits for Admin approval;
  the first account ever becomes admin), `settings` (key `main`: commission, lead_pct, currency, slots, areas, categories, payment_note –
  readable by the public), `catalog` (fixed fee per item, crew size, minutes), `jobs` (one booking = one job; items/prices snapshotted;
  status new → assigned → accepted → travelling → arrived → in_progress → finished → done | cancelled;
  v1.2 adds `issue` (customer won't sign – staff decide) and `failed_visit` (nobody home – fee kept)).
- Jobs are only created/changed through RPCs: `create_booking` (prices computed in SQL), `cancel_booking`, `assign_job`, `job_action`
  (accept/decline/travel/arrive/start/finish/photo/complete/no_sign/nobody_home – lead only for steps), `mark_paid` (Admin), `assembler_list`,
  `report_problem` (customer, within `dispute_hours` of completion), `resolve_job` (staff: accepted/revisit/partial/full/rejected; revisit
  creates a ₱0 job with `revisit_of`), `cancel_fee` (what cancelling now costs). Trigger `block_unpaid`: customers with an unpaid job/fee
  older than the problem window can't book. `job_due()` = what the customer owes (total − refund, or the kept fee).
- v1.4 assembler sign-up: `applications` (one per user: status draft/booked/passed/failed/no_show, `data` jsonb, `docs` jsonb id/nbi/med
  {path, ok, note}, Mober employees need only `med` + `emp_verified`), `eval_slots` (hub name, starts_at, seats). Role `evaluator`
  (`is_evaluator()` = admin or evaluator). RPCs: `app_me`, `app_save`, `app_doc`, `eval_slot_list`, `app_book` (move once, ≥2 h before),
  `app_cancel`, `app_list`, `app_doc_review`, `app_emp_verify`, `app_decide` (passed → role assembler). Private bucket `apps/<user id>/…`.
  Settings: hubs [{id,name,address}], joining_fee (0 = free), min_age 21, eval_minutes, skills, eval_items [{id,sec,label}] scored 1–5.
  An applicant = customer with requested_role 'assembler' (nav `applicant`: My application first).
- v1.5 payouts (every Monday, GCash, Taskadoo pays transfer fees): `payouts` (one per assembler per run: pending/sent/cancelled,
  GCash snapshot, reference) + `payout_lines` (unique job_id+assembler_id – never paid twice). `job_shares(job)` = the same split as
  the app. RPCs `payout_ready(p_end)` (closed, past dispute_hours, no open dispute, paid or enterprise, not yet in a payout),
  `payout_create`, `payout_mark_sent`, `payout_cancel` (Admin). GCash on `profiles.gcash_name/gcash_number` (copied on pass).
  Payout amounts are shown exact (`money2`). UI: Payments → "To assemblers"; assembler Earnings shows payout status/history.
- v1.7 assembler app: `profiles.online/online_at` (switch counts for today only), `avail` jsonb {week:{mon:{m:hours|off|shift,from,to}}, off:[dates]},
  `skills`, `radius_km`, `mober_emp` (Admin sets in Users; copied on pass). `avail_on(profile,date,slot)` → ok/time_off/shift/day_off/outside;
  `assign_job` refuses time_off and shift; `assembler_list(p_date,p_slot)` adds online, avail, rating. Jobs: `paused_at/paused_secs` (job_action
  pause/resume), `checks` (arrival box checks on start), `addons`/`addons_total` (job_action addons {ids}; prices from settings `addons`, included in
  `total`), `rating/rating_note/rated_at` via `rate_job` (customer, once, 14 days; seen only by staff + the job's assemblers). `assembler_stats(uid)`
  = rating, acceptance, on-time (settings `late_min`), first-visit. Settings `photo_min` (finished-work photos before sign-off, client-side).
- All times on screen use `TZ = 'Asia/Manila'`.
- v1.6 customer pages follow the landing design (system font -apple-system/Segoe UI, weights ≤ 700, colours from the design):
  guests and customers/enterprise get `renderSite()` (design header + footer, `CAT_META` titles/blurbs, `TINTS` per SKU,
  item cards, navy cart bar, two-column quote). Guests can browse and quote without an account (`GUEST_ROUTES`); Confirm
  booking sends them to sign-up and back (`S.next`, checkout draft `CD` in sessionStorage). Staff/assemblers keep the app shell.
- Rules in settings `main`: dispute_hours 24, cancel_free_hours 24, cancel_fee 300, fail_pct 30, fail_max 500, nobody_wait_min 15.
- Storage bucket `jobs` (private): photos and signature at `<jobId>/<file>`; upload only by the job's assemblers once arrived.
- Payment in Phase 1: customer pays after sign-off (cash/GCash/bank); Admin marks it paid. Assembler payouts are "held" for the
  problem window, "on hold" during a dispute/issue, then "ready" once the customer has paid.
- Payment plan agreed with Dennis: Step 2 = pay the full amount at booking via a provider (PayMongo/Xendit – none yet), held until
  sign-off + 24 h, refunds from the decision screen; Step 3 = weekly assembler payouts. Say "Payment held by Taskadoo", not "escrow".

## Before shipping any change
1. Check the JS (page loads with no console errors) and try every role's screens on a phone width and a computer width
   (no "undefined", "NaN" or "Invalid Date" on screen).
2. SQL changes: a new dated, idempotent file in `supabase/sql/`; tell Dennis exactly what to paste.
3. Add an entry at the top of `WHATSNEW` in `staging/app/index.html` (version, date, plain-English title, `changes` with
   kind New / Improved / Fixed and `for` = roles that see it, `where:'staging'` until it is copied to production, then `'live'`).
   Add its tests to `WN_TESTS[version]` ([id, who, title, steps, should happen]); "who" names the role(s) that can do it.
   Testers are non-technical: plain words, preparation in `WN_SETUP[id]`. After fixing a reported problem add
   `WN_FIXED[id]="<ISO time>"` so the test comes back first as "please test again".
   Results live in table `test_results` (staging); Dennis pastes them back with "Copy results for Claude".
4. Admin "Preview the app as" (`S.preview`, `inPreview()`, `ME()` = the person whose screens are shown): look-only –
   `updateProfile`, `saveSettings`, `saveItem`, `rpc` (except `assembler_list`) and `upload` are refused while previewing.
   Views must use `ME()` / `role()`, not `S.me`, for whose data they show.

## Agreed with Dennis – NOT built yet (wait until he says "build"; he says "remember" for items to keep here)
- Distance matching (OpenStreetMap, free): Taskadooer home address + map pin at sign-up (and in Profile for existing ones, staff-only);
  customer drops/confirms a map pin when booking; Dispatch suggests Taskadooers within a radius (Settings, default 30 km), nearest
  first, straight-line km, also respecting each one's own travel radius; "show anyway" for further ones.
- B. Manual + time limit: dispatcher picks; the assembler has N minutes (Settings, e.g. 30) to accept, else the offer returns to
  Dispatch as "Not answered".
- C. Open job board: dispatcher taps "Offer to all available" – everyone online, free that day and within the radius sees it;
  first to accept gets it.
- New Taskadooer sign-up, DrayberFlex-style (reuse its camera frame + Tesseract.js OCR + parseLicense from
  /home/user/drayberflex index.html "license & NBI upload with OCR"), English text, in the assembler-app phone layout, no "Book" tab:
  1 driver's license: "Take a photo" (camera with card frame) OR "Upload from gallery" → OCR fills name, sex, birthday, license no., expiry, DL codes, address ("Do you still live here?");
     DL code A (motorcycle) REQUIRED – can't continue without it; address + map pin = home for distance matching;
     one license = one person (check in SQL); expired license allowed but flagged.
  2 contact: mobile, email, password (creates the account), GCash; NBI + medical photos optional (can bring later).
  3 about 5 quick questions (experience, own tools, what they can build, part/full-time, Mober employee).
  4 pick day/time exactly like DrayberFlex (vApply calendar step): Admin sets per-hub RULES once (days open, start/end hours,
    interview length, seats per time, booking window days, closed times) → times generated automatically (replaces hand-made
    eval_slots). One screen: left = hub, length, distance/travel time from home, "contact info correct?" tick; middle = month
    calendar, days with free times in blue; right = times of the chosen day ("2 slots left"), tap time → Book. ≥1 h ahead,
    full times hidden, race-safe ("someone just booked that time"). Walk-in QR poster at the hub → same sign-up, slot today.
    5 QR ticket to show at the hub; evaluator scans it to open the application.
  Failed → same license may re-apply after 3 months (Settings); fake document etc. blocked for good.
- Later (Phase 3): full auto cascade from the design (90 s → next → blast top 5–8 → widen → human).
- DECIDED: say "Taskadooer" instead of "assembler" on every screen (text only; role names in the database stay).
- Video self-intro: advised against (drop-off, mobile data, storage, privacy). Offered instead: optional "Show your past work"
  (up to 3 photos) – waiting for Dennis's answer.

## Roadmap
- Phase 1 (built): roles + login, catalogue, booking, dispatch, assembler web app (accept → photos → signature), payments marked by Admin.
  v1.1: What's new page, test checklists (🧪 Tests), Preview the app as.
  v1.7: assembler app per the design (online switch, calendar, box checks, pause, guided photos, add-ons, ratings, scores).
  v1.5: weekly assembler payouts (manual GCash, reference numbers).
  v1.4: assembler sign-up + evaluation (Evaluator role, calendar, document checks, scorecard). v1.3: catalogue CSV import/export.
  v1.2: problems after the job, missed visits, late-cancel fee, payout holds, unpaid block, Settings + Catalogue redesign.
- Phase 2: (done: assembler registration + evaluation) enterprise portal (CSV upload, billing, self-dispatch). Payouts done manually (v1.5); automatic via provider later.
- Phase 3: receipt upload + pricing desk, auto-matching/offer cascade, Thailand (THB, Thai), native app if push/background location needed.

## Files
- `originals/` – the exported design files exactly as Dennis sent them, plus `build.py`, which makes a
  page from an export: `python3 originals/build.py <export.html> <out.html> "<title>" <1=staging|0=production>`.
- The exports are self-contained bundles (React, fonts and images embedded); the page content is a JSON string
  inside the file. Edit content in the design tool and re-export when possible.
- Never put secret keys or passwords in this repo – it is public.
