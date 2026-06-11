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

Run the install from the directory where your agent works (skills land in
`./.agents/skills/` and are picked up by Cursor, Claude Code, Codex, Amp, and others).

## Typical workflow: onboarding a new county

1. **Clone the repos.** Work happens in a checkout of `oracle-node` with sibling repos
   next to it:

```bash
mkdir elephant && cd elephant
git clone https://github.com/elephant-xyz/oracle-node
git clone https://github.com/elephant-xyz/Counties-trasform-scripts
git clone https://github.com/elephant-xyz/elephant-query-db
git clone https://github.com/elephant-xyz/lexicon   # optional, for lexicon-gap work
cd oracle-node && npm install
```

2. **Install the skills** into the `oracle-node` checkout:

```bash
npx skills add elephant-xyz/skills --all -y
```

3. **Prerequisites.** An AWS profile with access to the target account (existing
   `elephant-oracle-node` stack or permissions to deploy one), `gh` authenticated for
   PRs, Node 22+, and — for local portal probing — a US egress IP (VPN/proxy if you are
   outside the US; many county portals geo-block).

4. **Prompt the agent.** Open your agent in the `oracle-node` checkout and start with
   something like:

> Onboard Palm Beach county, FL into the oracle-node pipeline using the
> `onboard-county` skill. Start with a pilot of ~25 parcels.

   The skill begins with an intake (AWS profile/region, seed data, existing assets,
   sources, additional data sources like Sunbiz/BBB, scope, target DB). Answer once;
   after that it runs all stages autonomously — discovery, seed CSV, appraisal wiring,
   transform validation, permit adapter, pilot run, full run, enrichment, query-DB
   reconciliation — interrupting only for genuine blockers.

   You can also invoke any stage skill directly, e.g.:

> Run the `county-discovery` skill for Hillsborough county, FL.

> Use `monitoring-county-ingestion` to report current Palm Beach ingestion status.

5. **Results.** Findings docs and county scripts get PR'd to
   `Counties-trasform-scripts`; pipeline code lands on a `<county>-property-first-ingest`
   branch of `oracle-node`; data flows to S3 and the Neon query DB.

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
