---
name: deploy-open-data-mcp
description: Deploy your own Elephant open-data MCP server so any agent can query the published county property data (and request on-demand permits) from your preferred platform — Vercel, Cloudflare, AWS Lambda, or a plain Node server. The MCP is stateless and reads the public IPNS/IPFS open data, so every consumer runs their own copy pointing at the same data — no shared backend. Use when someone wants to consume the Oracle open data via MCP, self-host the MCP, or pick a serverless platform for it.
metadata:
  author: elephant-xyz
---

# Deploy the Open-Data MCP (any platform)

The Elephant open-data MCP (`elephant-xyz/elephant-mcp`) exposes the published county
property data as MCP tools. It is **stateless** — one fresh MCP server + transport per
request — and reads the data straight from **public IPFS via an IPNS pointer**. There is no
private database and no shared backend: **anyone who wants the data deploys their own MCP**
pointing at the same public IPNS name. This is the open-data model — see
`county-open-data-publish` for how the data + IPNS name are produced.

Tools it serves (open-data path): `listOracleProperties`, `getOracleProperty` (read the
sharded index → shard → per-property JSON), and `getPropertyPermits` (on-demand permit
harvest — optional, needs an SQS queue, see below).

## 1. Pick a platform → build

Write once, deploy anywhere. The build is a [Nitro](https://nitro.build) preset; the MCP
runs unchanged on all of them because it holds no per-session state.

```bash
git clone https://github.com/elephant-xyz/elephant-mcp && cd elephant-mcp && npm install

npx nitropack build --preset vercel            # Vercel
npx nitropack build --preset cloudflare-pages  # Cloudflare Pages/Workers
npx nitropack build --preset aws-lambda        # AWS Lambda (API Gateway / Function URL)
npx nitropack build --preset node-server       # plain Node (default) — also: npm run dev:http
```

`NITRO_PRESET=<preset>` works too. For Vercel use the bundled script
`npm run build:vercel` (it runs the `patch-nitro-noble.mjs` post-build fix for the
`@noble/hashes` package layout in the flattened bundle). The MCP endpoint is **`POST /mcp`**.

## 2. Configure env

| Variable | Required? | Purpose |
|---|---|---|
| `ORACLE_OPEN_DATA_IPNS` | **Yes (recommended)** | The published IPNS name (`k51q…`) for the county. The MCP resolves it live → always serves the latest index, no redeploy on re-publish. Get it from `county-open-data-publish` (Filebase `GET /v1/names/<label>` → `network_key`). |
| `ORACLE_OPEN_DATA_INDEX_CID` | Optional | Pin a fixed sharded-index CID instead of IPNS (you must redeploy to update). Leave UNSET when using IPNS so IPNS is the single source of truth. |
| `ORACLE_OPEN_DATA_MANIFEST_CID` | Optional | Legacy flat-manifest CID (back-compat). Prefer the sharded index. |
| `PERMIT_HARVEST_QUEUE_URL` | Only for permits | SQS queue URL the `getPropertyPermits` tool enqueues to (standard queue). |
| `PERMIT_HARVEST_OUTPUT_PREFIX` | Only for permits | S3 prefix where the permit worker writes results. |
| `PERMIT_CACHE_MANIFEST_CID` | Optional | IPFS manifest of already-harvested permits (served from cache before enqueuing). |
| `AWS_REGION` + credentials | Only for permits | Standard AWS credential chain (env keys, `AWS_PROFILE`, or the platform's IAM role / `AWS_CONTAINER_CREDENTIALS_*`). Needed only by the permit tool. |
| `OPENAI_API_KEY` | Optional | Embeddings for `getVerifiedScriptExamples`. On AWS it falls back to Bedrock Titan automatically if unset. |
| `PORT` / `MCP_HTTP_STANDALONE` | node-server only | Standalone Node HTTP server (`npm run start:http`). |

**Minimum to serve property data:** just `ORACLE_OPEN_DATA_IPNS`. Permits are additive and
only needed if you want the on-demand permit tool.

## 3. Deploy per platform

- **Vercel:** `vercel deploy` (or connect the repo) with build command `npm run build:vercel`
  and output preset `vercel`. Set the env vars in the project. Endpoint:
  `https://<project>.vercel.app/mcp`.
- **Cloudflare:** `npx nitropack build --preset cloudflare-pages` → `npx wrangler pages deploy
  .output/public` (set vars via `wrangler`/dashboard). Endpoint: `https://<pages>.dev/mcp`.
- **AWS Lambda:** `--preset aws-lambda` → deploy `.output` behind a Function URL or API
  Gateway (SAM/CDK/console). Give the role SQS `SendMessage` (+ Bedrock invoke if using the
  embeddings fallback). Endpoint: the Function URL + `/mcp`.
- **Node / container:** `npm run build && npm run start:http` (or `dev:http` for local).
  Endpoint: `http://<host>:<PORT>/mcp`.

## 4. Point a client at it

- **HTTP (your deploy):** configure the MCP client with a streamable-HTTP server URL of
  `https://<your-deploy>/mcp`.
- **stdio (no deploy, local):** the published package runs over stdio —
  `npx -y @elephant-xyz/mcp@latest` (the README has one-click Cursor/VS Code install links).
  Set the same `ORACLE_OPEN_DATA_IPNS` in the client's MCP env block.

## 5. Verify

```text
listOracleProperties { "limit": 2 }   # returns real properties; total == published count
getOracleProperty { "parcelId": "<a known parcel>" }   # full consolidated record
```

- IPNS proof: with `ORACLE_OPEN_DATA_IPNS` set and no fixed index-CID env, data still loads
  → it is resolving via IPNS, so a re-publish flips it with no redeploy (after the manifest
  cache TTL).
- If `listOracleProperties` is empty: confirm `ORACLE_OPEN_DATA_IPNS` is the current
  `network_key` and that `GET /v1/names/<label>` points at a live index CID.

## Related skills

- `county-open-data-publish` — produces the data + the IPNS name this MCP reads.
- `query-db-loading-matching` — loads the data that gets published.
