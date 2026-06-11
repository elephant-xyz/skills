---
name: county-discovery
description: Research a new US county before onboarding it to the oracle-node ingestion pipeline - appraiser portal, permit portal vendor, parcel id format, bulk data sources, and anti-bot posture. Use when asked to onboard, evaluate, or scope a new county, or when planning appraisal/permit scraping for a county not yet ingested.
metadata:
  author: elephant-xyz
---

# County Discovery

Source preferences (which appraisal/permit websites, prior findings, additional sources)
come from the `onboard-county` intake — don't re-ask what's already established. If
entered directly without that context, gather those answers once (plus
`AWS_PROFILE`/`AWS_REGION`) before probing, then proceed without further check-ins.

Produce a county profile document before writing any code. The profile feeds every later
stage: seed data, browser flow, transform scripts, permit adapter, eligibility mapping.

## Output

Write findings to `oracle-node/docs/<county>-county-findings.md`. Required sections:

1. **Appraiser portal** — base URL, per-parcel detail URL pattern, search mechanism,
   access mode per artifact (plain fetch / modified request replaying a hidden API /
   real browser), CAPTCHA/Cloudflare posture.
2. **Parcel identifier** — official name (STRAP, PCN, folio…), format, punctuation,
   numeric-only variants, how it appears on appraiser vs permit portals (often different).
3. **Permit portal** — vendor (Accela, Tyler, ePZB, custom), search-by-parcel support,
   detail page contents (contractors, inspections, fees), session requirements, rate
   tolerance.
4. **Bulk data sources** — county parcel roll download (seed source), GIS/open-data portals.
5. **Usage-type vocabulary** — the appraiser's property use codes/labels, and which map to
   commercial/industrial (drives permit-harvest eligibility).
6. **Additional data sources** — inventory what else is available for the county (the
   NETR directory step surfaces most of these): business registrations (Sunbiz for FL),
   contractor reputation (BBB), tax collector rolls, recorder/official records (deeds,
   mortgages, liens), GIS/parcel geometry, code enforcement, business licenses. For each:
   URL, bulk-download availability, and whether the operator wants it in scope. Lee
   shipped with two beyond appraisal+permits (Sunbiz, BBB); treat that as the baseline to
   offer, not the ceiling.
7. **Risks** — geo-blocking, bot challenges, throttling expectations.

## Workflow

1. Check prior art first:
   - `oracle-node/docs/` for existing findings docs (Lee is the reference).
   - `transform/<county>/` in oracle-node and the county folder in
     `github.com/elephant-xyz/Counties-trasform-scripts` — if transform scripts exist,
     the appraisal side has been at least partially solved before.
   - `browser-flows/` for an existing flow JSON for the county.
2. Enumerate official data sources via the NETR Online directory:
   `https://publicrecords.netronline.com/state/<STATE>/county/<county>` — it lists the
   county's assessor/appraiser, recorder, tax collector, GIS/mapping, and
   building/permit offices with links to their official sites. Use it to find the
   appraiser portal, permit portal, and bulk-download pages instead of guessing URLs;
   verify each linked site is the current official one.
3. Probe each source with a real parcel id (get a few from the county GIS/open data).
   Always explore with Playwright, even when `curl` works — see "Exploring with
   Playwright" below. Record per source: curl-only / curl-partial / browser-required,
   and the full inventory of data the browser reveals.
4. Identify the permit vendor by URL shape:
   - `*.accela.com/<AGENCY>/...` → Accela Citizen Access. Record the agency code, module
     name (usually `Permitting`), and record-number prefixes (used to classify record types).
   - Otherwise capture the search flow with browser devtools and note the JSON/HTML
     endpoints.
5. Capture 3-5 sample permit detail pages and 3-5 appraisal pages covering different
   property types (commercial, industrial, residential, condo, vacant) — save HTML to
   `downloads/<county>/samples/`. These become fixtures for transform validation and the
   permit adapter.
6. Florida-specific: Sunbiz corporate data is statewide — only the county ZIP-prefix list
   is new. Collect the county's ZIP codes.

## Exploring with Playwright

Never conclude a source's data inventory from `curl` output alone. A `curl` probe answers
"is there bot protection?", not "what data exists". The failure modes it hides:

- **Blocked outright** — Cloudflare/bot challenges return errors or challenge pages while
  a real browser works (Palm Beach permits require a Playwright session via
  `iPZB.Building/Session` before its API answers; Sunbiz blocks curl entirely).
- **Partial data** — the initial HTML loads fine but tabs, accordions, "more details"
  expanders, and lazy/XHR-loaded sections (valuations, sales history, permits tab, photos,
  cost cards) only materialize after JS runs or a click. Lee's Accela detail pages and
  appraiser cost cards are examples — the richest data sat behind expanders.
- **Hidden APIs** — the page is driven by JSON endpoints that curl CAN fetch, but only
  with the right headers/cookies/POST body discovered from browser traffic.

For every page type (search results, detail page, each tab):

1. Open it in Playwright; wait for network idle; click through every tab/expander/
   pagination control; scroll to trigger lazy loads.
2. Record all network requests (`page.on('request'/'response')` or HAR) and identify the
   underlying data endpoints — JSON APIs are preferable scrape targets over HTML.
3. Diff what the rendered DOM contains vs the raw `curl` HTML of the same URL; anything
   browser-only must be captured by the browser flow or via the discovered endpoint with
   a modified request (copy headers, cookies, session bootstrap, POST params).
4. Document per source: required session/bootstrap steps, endpoints + required
   headers/params, and which artifacts need a real browser vs a modified plain request.

This inventory feeds `validate-county-transform` — fields missed here become silent
coverage gaps later.

## Reference example

Lee County profile: Accela at `aca-prod.accela.com/LEECO/...` (no CAPTCHA, tolerates
concurrency ~3-4), appraiser `leepa.org` via browser flow with STRAP search, seeds from
the county roll at `s3://counties-seeds/lee.csv` (~516k parcels).

Palm Beach (prototyped): appraiser `pbcpao.gov/Property/Details?parcelId=<PCN>`; permits
NOT Accela — `pbc.gov/ePZB` guest endpoints (`iPZB.Building/guest/pcnpermits/<PCN>` and
`EPR_BLDG/PermitSearch/GetGuestPermitsRec`), curl blocked, Playwright required.
