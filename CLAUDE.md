# Taskadoo – project brief for Claude Code

## What this is
Taskadoo: on-demand flat-pack furniture assembly (Philippines) – customer site, assembler app, dispatcher,
enterprise portal, admin. Right now the pages are **clickable design prototypes** (no backend, no real data).
Owner: Dennis (non-technical). Explain changes in plain language, one step at a time, confirm before big changes.

## Live setup
- GitHub Pages from repo `thegreenzilla/taskadoo`, branch `main`, folder `/ (root)`.
- **Staging** (try changes here first): `staging/` → https://thegreenzilla.github.io/taskadoo/staging/
  - `staging/index.html` – customer landing page
  - `staging/app/index.html` – apps prototype (assembler app, dispatcher, enterprise portal, admin)
  - Staging pages carry `noindex` and a red STAGING badge (bottom-left).
- **Production**: repo root → https://thegreenzilla.github.io/taskadoo/
  Currently a "Coming soon" placeholder. Going live = copy the staging pages to the root
  (`index.html`, `app/index.html`) without the badge and without `noindex` (`build.py ... 0`).
- Workflow: change staging → Dennis tries it → copy the same change to production.

## Files
- `originals/` – the exported design files exactly as Dennis sent them, plus `build.py`, which makes a
  page from an export: `python3 originals/build.py <export.html> <out.html> "<title>" <1=staging|0=production>`.
- The exports are self-contained bundles (React, fonts and images embedded); the page content is a JSON string
  inside the file. Edit content in the design tool and re-export when possible.
- Never put secret keys or passwords in this repo – it is public.
