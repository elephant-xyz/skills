# Elephant Oracle Skills

Agent skills for onboarding and running US-county property-data ingestion with the
[elephant-xyz/oracle-node](https://github.com/elephant-xyz/oracle-node) pipeline:
appraisal scrape → lexicon transform → permit harvest → Sunbiz/BBB enrichment → Neon query DB.

Lee County, FL was the first full implementation; these skills generalize that exercise so
any county (Palm Beach is the reference second county) can be onboarded repeatably.

## Install

```bash
# Interactive picker
npx skills add elephant-xyz/skills

# Everything, non-interactive
npx skills add elephant-xyz/skills --all -y

# One skill
npx skills add elephant-xyz/skills --skill onboard-county
```

## Skills

| Skill | Purpose |
|---|---|
| `onboard-county` | Orchestrator: sequences the full county onboarding, links all stage skills |
| `bootstrap-oracle-infra` | Verify/bootstrap AWS stacks, buckets, secrets, Neon DB prerequisites |
| `county-discovery` | Research a new county: appraiser portal, permit vendor, parcel format, anti-bot posture |
| `county-seed-data` | Produce and stage the parcel seed CSV in `counties-seeds` |
| `county-appraisal-onboarding` | Browser flow, per-county prepare queue, transform scripts wiring |
| `validate-county-transform` | Prove transform scripts extract 100% of available data across variability |
| `county-permit-adapter` | Build the county permit-portal harvester module (Accela template + generic path) |
| `county-ingest-run` | Deploy, start the backpressure-aware seed feeder, run end-to-end |
| `monitoring-county-ingestion` | Queue health, S3 artifact counts, Neon counts, ETAs for any county |
| `query-db-loading-matching` | Load artifacts into Neon and cross-match by parcel id / address hash |
| `sunbiz-corporate-ingest` | Florida statewide Sunbiz corporate bulk ingest + lexicon transform |
| `bbb-harvest` | BBB contractor category harvest for reputation/quality enrichment |
| `transform-v2-builder` | Author/repair county transform handler packages for elephant-cli transform v2 |

## Conventions

- All skills assume work happens in a checkout of `oracle-node` (and sibling repos
  `elephant-query-db`, `Counties-trasform-scripts`, `lexicon` where noted).
- AWS access: `AWS_PROFILE` + `AWS_REGION` environment variables; skills never hardcode accounts.
- Default branch of this repo is the release channel for `npx skills update`.
