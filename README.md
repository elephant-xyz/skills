# Elephant Oracle Skills

Agent skills for onboarding and running US-county property-data ingestion on a local
durable workflow stack (Restate + Postgres in Docker Compose, artifacts on the local
filesystem):
appraisal scrape → lexicon transform → permit harvest → Sunbiz/BBB enrichment → query DB.

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

## Quickstart: onboarding a new county

1. **Clone the repos.** Work happens in a checkout of `elephant-pipeline` — the
   `bootstrap-oracle-infra` skill scaffolds it if missing — with sibling repos next
   to it:

```bash
mkdir elephant && cd elephant
git clone https://github.com/elephant-xyz/Counties-trasform-scripts
git clone https://github.com/elephant-xyz/elephant-query-db
git clone https://github.com/elephant-xyz/lexicon   # optional, for lexicon-gap work
```

2. **Install the skills** into the `elephant-pipeline` checkout (or `elephant/` before
   it exists):

```bash
npx skills add elephant-xyz/skills --all -y
```

3. **Prerequisites.** Docker, Node 22+, the `restate` CLI
   (`brew install restatedev/tap/restate`), `gh` authenticated for PRs, and — for portal
   scraping — a US egress IP (VPN/proxy if you are outside the US; many county portals
   geo-block). No cloud account is needed for the local ingestion stack; publishing to
   public IPFS requires Filebase credentials (a free tier exists).

4. **Prompt the agent.** Open your agent in the checkout and start with something like:

> Onboard Palm Beach county, FL into the pipeline using the `onboard-county` skill.
> Start with a pilot of ~25 parcels.

   The skill begins with an intake (local stack status, seed data, county, sources,
   Sunbiz/BBB enrichment, scope, US egress, target DB). Answer once; after that it runs
   all stages autonomously — discovery, seed CSV, appraisal wiring, transform
   validation, permit adapter, source feasibility, pilot run, full run, enrichment,
   query-DB reconciliation — interrupting only for genuine blockers. Sources that would
   take more than 48 hours to fully download trigger an explicit choice: download
   anyway, ingest into the database, or retrieve from the owning app at runtime.

   You can also invoke any stage skill directly, e.g.:

> Run the `county-discovery` skill for Hillsborough county, FL.

> Use `monitoring-county-ingestion` to report current Palm Beach ingestion status.

5. **Results.** Findings docs and county scripts get PR'd to
   `Counties-trasform-scripts`; pipeline services live in your `elephant-pipeline`
   checkout; data lands under `elephant-pipeline/data/` and in Postgres, then publishes
   to IPFS when publishing is in scope and approved.

## Skills

| Skill | Purpose |
|---|---|
| `onboard-county` | Orchestrator: sequences the full county onboarding, links all stage skills |
| `bootstrap-oracle-infra` | Verify/bootstrap the local stack: Restate, data directories, Postgres, service registration |
| `durable-workflow-builder` | Patterns for authoring the pipeline's durable services: feeder backpressure, idempotent steps, error taxonomy, approval gates |
| `county-discovery` | Research a new county: appraiser portal, permit vendor, parcel format, anti-bot posture, source feasibility |
| `county-seed-data` | Produce and stage the parcel seed CSV under `data/seeds/` |
| `county-appraisal-onboarding` | Browser flow, `Parcel` service wiring, transform scripts per county |
| `validate-county-transform` | Prove transform scripts extract 100% of available data across variability |
| `county-permit-adapter` | Build the county permit-portal harvester module (Accela template + generic path) |
| `county-ingest-run` | Start the `CountyIngest` feeder with a bounded window, run end-to-end, resume failures |
| `monitoring-county-ingestion` | Invocation health via Restate UI/SQL, artifact counts, DB counts, ETAs |
| `query-db-loading-matching` | Load artifacts into the query DB and cross-match by parcel id / address hash |
| `county-open-data-publish` | Publish property data to IPFS (Filebase) as 1-file-per-property + sharded index, with a stable IPNS pointer the MCP reads |
| `county-query-table-publish` | Export the flat per-county query-table Parquet → validate (rows == distinct folio) → publish to its own IPNS → wire the MCP's `PROPERTY_QUERY_TABLE_MAP` |
| `deploy-open-data-mcp` | Run your own stateless open-data MCP serving the published data via IPNS — per-consumer, no shared backend |
| `sunbiz-corporate-ingest` | Florida statewide Sunbiz corporate bulk ingest + lexicon transform |
| `bbb-harvest` | BBB contractor category harvest for reputation/quality enrichment |
| `overture-places-ingest` | County-clipped Overture business/POI locations with taxonomy, source-licence, Neon coverage, and dedicated IPFS publication gates |
| `transform-v2-builder` | Author/repair county transform handler packages for elephant-cli transform v2 |
| `use-elephant-mcp` | Operating guide for exploring published Oracle open-data and Overture places through the `elephant` MCP server |

## Agents

These are routing definitions, not procedures. Skills hold the how-to.

| Agent | Purpose |
|---|---|
| [`agents/oracle.md`](./agents/oracle.md) | Routes onboard / ingest / refresh / publish work to the skills above |
| [`agents/donphan.md`](./agents/donphan.md) | Explores published county data through MCP tools only |

An example Cursor MCP config lives at [`mcp.json`](./mcp.json). County maps in that file
are generated from `oracle-node/catalog/published-counties.json` — see the
`use-elephant-mcp` skill. This repo is not a Cursor plugin; paste the example into the
client's MCP config.

## Conventions

- All skills assume work happens in a checkout of `elephant-pipeline` (and sibling repos
  `elephant-query-db`, `Counties-trasform-scripts`, `lexicon` where noted).
- The stack is local Docker Compose — Restate + Postgres — plus one Node services
  process; pipeline data lives under `elephant-pipeline/data/`. No cloud account needed
  for ingestion (Filebase credentials only for public IPFS publishing); config lives in
  `elephant-pipeline/.env`.
- Full-source scraping is gated by measured performance and safe concurrency. If a source
  is estimated above 48 hours, decide whether to download, ingest, or fetch it at runtime.
- Default branch of this repo is the release channel for `npx skills update`.
