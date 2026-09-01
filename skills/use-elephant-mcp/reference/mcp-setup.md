# Elephant MCP — setup

This repo is a **skills** repo, not a Cursor plugin. Copy the `mcp.json` at the root of
the `elephant-xyz/skills` repository into the client config (Cursor: `~/.cursor/mcp.json`).
The example uses Cursor's MCP schema so it pastes without further wrapping.

## Install source

Install **elephant-mcp `main`** from `github:elephant-xyz/elephant-mcp#main` because npm
`@elephant-xyz/mcp@latest` has historically lagged (lacked `queryProperties`). Pinning a
SHA is safer for production hosts; this example tracks `main` so `queryProperties` /
`queryPlaces` stay current until npm catches up.

Prefer a **built** `dist/index.js` for a local checkout (Node ≥26 refuses to import
`package.json` from raw TypeScript). Keep Zod v3. Never set an empty `OPENAI_API_KEY`.

**Teammate checklist:**

1. Node.js **22.18+** (`node -v`)
2. MCP server **`elephant`** listed and enabled (first `npx` GitHub install may take 1–3 minutes)
3. Optional: add `OPENAI_API_KEY` to the `elephant` server env **only if** you have a key and
   need `getVerifiedScriptExamples`. Do **not** set an empty key — elephant-mcp crashes on
   startup if `OPENAI_API_KEY` is present but blank.

**MCP server name:** always `elephant`. Donphan and this skill call tools on that server.

### Verify connectivity

Call `getOracleDatasetInfo` with the county under discussion. A healthy Lee County response
includes `county: "lee"`, `propertyCount` around **511695**, and export timestamps. For other
counties, pass `county` explicitly (kebab-case slugs). Omitting `county` reports Lee.

Verified baselines (regression checks, not a closed list):

| County | `county` arg | Expected `propertyCount` (approx.) |
|--------|--------------|-------------------------------------|
| Lee | _(omit or `"lee"`)_ | ~511695 |
| Palm Beach | `"palm-beach"` | ~653945 |
| Miami-Dade | `"miami-dade"` | ~933087 |

SQL counts/filters via `queryProperties` work for every county in `PROPERTY_QUERY_TABLE_MAP`.
Current elephant-mcp also uses that map as the primary source for `getOracleProperty`,
`listOracleProperties`, `getOracleDatasetInfo`, and geo tools — a county listed there needs
no `ORACLE_*` vars. `ORACLE_OPEN_DATA_IPNS_MAP` in the example is a 4-county fallback
(lee, palm-beach, miami-dade, orange) for the legacy open-data path.

If `propertyCount` is **~4664** and `ipnsName` is null, see troubleshooting below.

Overture places discovery is catalog-driven. Call `listPublishedCounties` and inspect
nullable `placesTableUrl`, then call `getPlaceQuerySchema`/`queryPlaces`. Lee currently
publishes **40,191** rows. A null `placesTableUrl` means the county has no published places
query table.

## Regenerating county maps from the catalog

Do **not** hand-edit `PROPERTY_QUERY_TABLE_MAP`. Generate it from
`oracle-node/catalog/published-counties.json` (9 published counties as of 2026-08-29).
Run the snippet **from the `oracle-node` checkout** (the `require` path is relative to that
cwd), or pass an absolute path:

```bash
# cwd = oracle-node
node -e "const c=require('./catalog/published-counties.json');
  console.log(JSON.stringify(Object.fromEntries(
    c.counties.filter(x=>x.queryTableUrl).map(x=>[x.countyKey,x.queryTableUrl]))))"
```

Same file, `permitQueryTableUrl` → `PERMIT_QUERY_TABLE_MAP`; `datasetCoverageUrl` →
`DATASET_COVERAGE_MAP`. The example `mcp.json` was generated that way. The catalog
intentionally **drops `santa-clara`**, which older hand-maintained maps served; overlay it
locally with `PROPERTY_QUERY_TABLE_MAP_ADDITIONS` / `PERMIT_QUERY_TABLE_MAP_ADDITIONS` if
you still need it (elephant-mcp merges `*_MAP_ADDITIONS` over the base map).

## Example MCP config

Copy the repository-root `mcp.json`. **Smoke test:**
`bash -c 'exec npx -y --package=github:elephant-xyz/elephant-mcp#main mcp'`
should start the stdio server (Ctrl+C to stop).

### Local `elephant-mcp` development

Point `command` at `node dist/index.js` (after build) with `cwd` set to the checkout, using a
separate MCP entry (e.g. `elephant-local`).

## Environment variables

| Variable | Required for | Default / notes |
|----------|----------------|-----------------|
| `OPENAI_API_KEY` | `getVerifiedScriptExamples` (OpenAI path) | **Omit unless set**; empty value crashes startup |
| `AWS_REGION` | Bedrock embeddings | `us-east-1` |
| AWS credential chain | Bedrock when no OpenAI key | IAM role, env vars, or `~/.aws/credentials` |
| `PROPERTY_QUERY_TABLE_MAP` | `queryProperties`, and (on current elephant-mcp) property/geo/dataset-info primary path | Generated from `published-counties.json` `queryTableUrl` |
| `PROPERTY_QUERY_TABLE_MAP_ADDITIONS` | Overlay extra counties (local parquet, santa-clara, pilots) without rewriting the base map | Merged on top of the base map |
| `PERMIT_QUERY_TABLE_MAP` | `queryPermits`, `getPermitQuerySchema` | Generated from non-null `permitQueryTableUrl` (montgomery, rock-island) |
| `DATASET_COVERAGE_MAP` | `getOracleDatasetInfo` coverage | Generated from `datasetCoverageUrl` |
| `PUBLISHED_COUNTY_CATALOG_URL` | `listPublishedCounties`, places tools | Oracle's canonical catalog by default |
| `ORACLE_OPEN_DATA_IPNS_MAP` | Legacy open-data fallback | Lee, Palm Beach, Miami-Dade, Orange |
| `ORACLE_OPEN_DATA_DEFAULT_COUNTY` | County when a tool omits `county` | `lee` — always pass `county` for any other county |
| `ORACLE_GEO_INDEX_IPNS` | Geo fallback when a county is not in the query-table map | Lee reference index |
| `LOG_LEVEL` | Diagnostics | `info` |

At least one embedding provider is required only for `getVerifiedScriptExamples`. Schema and
Oracle open-data tools work without embeddings.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `elephant` missing in MCP panel | Reload the client; confirm `mcp.json` is in the config the client reads |
| County "not served" / `queryProperties` blocked | County missing from maps — ingest via `oracle` + `onboard-county`, publish query table, regenerate maps from the catalog. Santa Clara is absent from the catalog by design; overlay with `*_MAP_ADDITIONS`. |
| `getPlaceQuerySchema` / `queryPlaces` missing | Update elephant-mcp GitHub `main`, reload, confirm the `elephant` server restarted |
| Places unavailable / `placesTableUrl is null` | The canonical catalog has no places artifact for that county; do not bypass through Neon or direct IPFS |
| Places query times out | Retry once after the public IPNS gateway resolves; if repeated, report the 60-second MCP timeout and catalog URL without switching data paths |
| `propertyCount` ~4664, `ipnsName` null | Add open-data IPNS (or county map entry) to server env and reload |
| `propertyCount` ~4664, `ipnsName` set | IPNS still points at pilot manifest — full county open-data publish + IPNS re-point needed |
| Geo answers look like Lee for another county | Pass `county` on geo tools; omitting it defaults to Lee |
| `getVerifiedScriptExamples` fails | Add a real `OPENAI_API_KEY` to server env, or configure AWS Bedrock credentials |
| First query is slow | `npx` clones GitHub and builds elephant-mcp on first start — can take 1–3 minutes |
| `elephant` red / install fails | Confirm Node **22.18+**; run smoke test above |
| `npm error ENOTEMPTY` in `_npx` cache | Quit the client; `rm -rf ~/.npm/_npx`; run smoke test once; reopen |
| GitHub install blocked (proxy/firewall) | Use a local `elephant-mcp` checkout (`node dist/index.js` + `cwd`) |

## Related

| Task | Use |
|------|-----|
| Explore via MCP (this skill) | `donphan` agent |
| SQL over Neon | `elephant-query-db` live schema |
| Ingest / refresh county data | `oracle` + `onboard-county` |
