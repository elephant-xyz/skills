---
name: county-discovery
description: Research a new US county before onboarding it to the oracle-node ingestion pipeline - appraiser portal, permit portal vendor, parcel id format, bulk data sources, and anti-bot posture. Use when asked to onboard, evaluate, or scope a new county, or when planning appraisal/permit scraping for a county not yet ingested.
metadata:
  author: elephant-xyz
---

# County Discovery

Before probing anything: confirm with the operator which appraisal/permit websites should
be used (they may already know the portals), whether prior findings or sample captures
exist, and that sending light traffic to the county sites is OK from the current network.
If entered directly (not via `onboard-county`), also confirm `AWS_PROFILE`/`AWS_REGION`.

Produce a county profile document before writing any code. The profile feeds every later
stage: seed data, browser flow, transform scripts, permit adapter, eligibility mapping.

## Output

Write findings to `oracle-node/docs/<county>-county-findings.md`. Required sections:

1. **Appraiser portal** — base URL, per-parcel detail URL pattern, search mechanism,
   whether plain HTTP fetch works or a real browser is required, CAPTCHA/Cloudflare posture.
2. **Parcel identifier** — official name (STRAP, PCN, folio…), format, punctuation,
   numeric-only variants, how it appears on appraiser vs permit portals (often different).
3. **Permit portal** — vendor (Accela, Tyler, ePZB, custom), search-by-parcel support,
   detail page contents (contractors, inspections, fees), session requirements, rate
   tolerance.
4. **Bulk data sources** — county parcel roll download (seed source), GIS/open-data portals.
5. **Usage-type vocabulary** — the appraiser's property use codes/labels, and which map to
   commercial/industrial (drives permit-harvest eligibility).
6. **Risks** — geo-blocking, bot challenges, throttling expectations.

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
3. Probe the appraiser portal with a real parcel id (get a few from the county GIS/open
   data). Test plain `curl` first, then a headless browser. Record which works — several
   FL portals block curl but allow Chromium (Palm Beach permit portal requires a
   Playwright session via `iPZB.Building/Session` before API calls work).
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

## Reference example

Lee County profile: Accela at `aca-prod.accela.com/LEECO/...` (no CAPTCHA, tolerates
concurrency ~3-4), appraiser `leepa.org` via browser flow with STRAP search, seeds from
the county roll at `s3://counties-seeds/lee.csv` (~516k parcels).

Palm Beach (prototyped): appraiser `pbcpao.gov/Property/Details?parcelId=<PCN>`; permits
NOT Accela — `pbc.gov/ePZB` guest endpoints (`iPZB.Building/guest/pcnpermits/<PCN>` and
`EPR_BLDG/PermitSearch/GetGuestPermitsRec`), curl blocked, Playwright required.
