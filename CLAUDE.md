# Taskadoo – project brief for Claude Code

## What this is
Taskadoo: on-demand flat-pack furniture assembly (Philippines) – customer site, assembler app, dispatcher,
enterprise portal, admin. Right now the pages are **clickable design prototypes** (no backend, no real data).
Owner: Dennis (non-technical). Explain changes in plain language, one step at a time, confirm before big changes.

## Live setup
- GitHub Pages from repo `thegreenzilla/taskadoo`, branch `main`, folder `/ (root)`.
  Domain later: **taskadoo.asia** (main) with taskadoo.ph forwarding to it; staging will be `taskadoo.asia/staging/`.
- **Staging** (try changes here first): `staging/` → https://thegreenzilla.github.io/taskadoo/staging/
  - `staging/index.html` – customer landing page (design export, still a prototype)
  - `staging/app/` – **the real system** (Phase 1): `index.html` (vanilla JS, no build step), `config.js`
    (staging Supabase URL + publishable key, `STAGING:true`), `manifest.webmanifest`, `img/`
  - `staging/demo/index.html` – the original clickable apps design, kept as the reference for later phases
  - Staging pages carry `noindex` and a red STAGING badge.
- **Production**: repo root → https://thegreenzilla.github.io/taskadoo/ – "Coming soon" placeholder for now.
  Going live = copy staging files to the root with a production `config.js` (separate Supabase project `taskadoo`).
- Workflow: change staging → Dennis tries it → copy the same change to production.

## Backend (Supabase)
- Staging project `taskadoo-staging`, ref `khxlothqjbjcfdcgkzcd` (Singapore). "Automatically expose new tables" is OFF
  and automatic RLS is ON → every table needs explicit `grant`s and policies.
- SQL lives in `supabase/sql/` as dated, idempotent files; Dennis pastes them into SQL Editor. A new database = run all files in date order.
- Tables: `profiles` (role: customer, assembler, dispatcher, enterprise, admin; `requested_role` from sign-up waits for Admin approval;
  the first account ever becomes admin), `settings` (key `main`: commission, lead_pct, currency, slots, areas, categories, payment_note –
  readable by the public), `catalog` (fixed fee per item, crew size, minutes), `jobs` (one booking = one job; items/prices snapshotted;
  status new → assigned → accepted → travelling → arrived → in_progress → finished → done | cancelled).
- Jobs are only created/changed through RPCs: `create_booking` (prices computed in SQL), `cancel_booking`, `assign_job`, `job_action`
  (accept/decline/travel/arrive/start/finish/photo/complete – lead only for steps), `mark_paid` (Admin), `assembler_list`.
- Storage bucket `jobs` (private): photos and signature at `<jobId>/<file>`; upload only by the job's assemblers once arrived.
- Payment in Phase 1: customer pays after sign-off (cash/GCash/bank); Admin marks it paid.

## Roadmap
- Phase 1 (built): roles + login, catalogue, booking, dispatch, assembler web app (accept → photos → signature), payments marked by Admin.
- Phase 2: assembler registration + evaluation booking, enterprise portal (CSV upload, billing, self-dispatch), earnings payouts.
- Phase 3: receipt upload + pricing desk, auto-matching/offer cascade, Thailand (THB, Thai), native app if push/background location needed.

## Files
- `originals/` – the exported design files exactly as Dennis sent them, plus `build.py`, which makes a
  page from an export: `python3 originals/build.py <export.html> <out.html> "<title>" <1=staging|0=production>`.
- The exports are self-contained bundles (React, fonts and images embedded); the page content is a JSON string
  inside the file. Edit content in the design tool and re-export when possible.
- Never put secret keys or passwords in this repo – it is public.
