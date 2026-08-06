---
name: durable-workflow-builder
description: Author durable pipeline workflows for the elephant-pipeline project with Restate's TypeScript SDK — service topology, code skeletons, and the full pattern library (backpressure feeder, layered concurrency, deterministic keys, idempotent side effects, single-writer objects, approval gates) distilled from running the previous county pipeline at full scale. Use when building or modifying pipeline workflows, adding a service or handler, choosing between workflow vs service vs virtual object, wiring retries, concurrency caps, or approval gates, or debugging stuck or paused invocations.
metadata:
  author: elephant-xyz
---

# Durable Workflow Builder

All pipeline orchestration lives in `elephant-pipeline/services/` as TypeScript Restate
services in ONE Node process (`app.ts`, port 9080), registered with the local Restate
server from `docker-compose.yml` (ingress :8080, admin/UI :9070) — the stack is Restate
+ Postgres only. Files go to the filesystem under `elephant-pipeline/data/` (env
`DATA_DIR`), rows to Postgres via `DATABASE_URL`. See
`bootstrap-oracle-infra` for scaffolding; `county-ingest-run` for operating a run.

## Core model

Three service kinds — pick by state and keying:

- **Service** — stateless handlers, N concurrent invocations. Use for per-item work:
  `Parcel.process`, `PermitHarvest.harvestParcel`.
- **Virtual Object** — keyed, single-threaded per key, durable K/V state (`ctx.set/get`).
  Use where exactly-one-writer matters: `Loader` (key `<county>`, serial DB merges),
  `Publish` (key `<county>`, export→approve→IPNS loop).
- **Workflow** — a keyed `run` handler that executes exactly once per key. Use for jobs:
  `CountyIngest` (key `<county>-<jobId>`) and its `IngestChunk` children
  (key `<county>-<jobId>-c<N>`), `PermitFeed` (key = `<CountyIngest key>-permits`, so a
  redrive pass feeds `…-r2-permits`) and its `PermitFeedChunk` children
  (key `<PermitFeed key>-c<N>`), `SunbizIngest`/`BbbHarvest` (key `<jobId>`).

**Durable execution in two sentences:** every `ctx.*` action is journaled; on crash,
restart, or redeploy the invocation replays the journal and resumes exactly where it
stopped. State, timers, and calls survive process death — no checkpoint files, no
re-streaming, no watchdogs.

**Three authoring rules that make durability hold:**

1. Every side effect (fetch, upload, DB write, CLI exec) goes inside `ctx.run` AND must
   be idempotent — an interrupted step re-executes from its start, so file writes use
   deterministic paths and DB writes use `ON CONFLICT DO UPDATE`.
2. Never mutate a registered deployment under in-flight invocations — replay against
   changed code corrupts journals. Local dev: `restate deployments register --force` and
   wiping the `restate-data` volume are fine *until a real run is live*. This
   single-process topology has no second endpoint for a true new version, so during a
   live run: freeze code; ship an in-place fix ONLY if it is replay-compatible (no
   journaled steps added, removed, or reordered) via `--force` re-register — an explicit,
   accepted risk; otherwise cancel/drain the affected invocations and re-run them as a
   redrive pass (pattern 3) on the new code.
3. Long-blocking steps need raised service timeouts. Server defaults are **1 min
   inactivity / 10 min abort** — a handler stuck inside one `ctx.run` longer than that is
   aborted and the step re-runs from its start, forever. For services with
   multi-minute steps (`Loader` bulk loads, `Publish` export/upload, enrichment scans,
   `PermitHarvest` detail-heavy parcels and `Parcel` heavy captures — or split those
   into journaled search/list/detail steps),
   raise `inactivityTimeout`/`abortTimeout` in the service definition's options (or per
   service via the UI/CLI config) AND split the work into the smallest journaled steps
   that make sense. "No time limits" is true of the architecture only after this is set.

## Skeleton

`services/app.ts` — one endpoint binds everything:

```ts
import "dotenv/config";
import * as restate from "@restatedev/restate-sdk";
import { countyIngest, ingestChunk } from "./county-ingest";
import { parcel } from "./parcel";
import { permitHarvest, permitFeed, permitFeedChunk } from "./permit-harvest";
import { loader } from "./loader";
import { publish } from "./publish";
import { sunbizIngest, bbbHarvest } from "./enrichment"; // stubs until authored

restate.serve({
  services: [countyIngest, ingestChunk, parcel, permitHarvest, permitFeed,
             permitFeedChunk, loader, publish, sunbizIngest, bbbHarvest],
  port: 9080,
});
```

`services/county-ingest.ts` — the feeder, split in two so no journal grows unbounded:
the parent `CountyIngest` workflow spawns one `IngestChunk` child workflow per ~10k-row
slice (parent journal ≈ one entry per chunk), and each chunk dispatches `Parcel.process`
in bounded windows (the next window is admitted when the previous one completes; a chunk
journal stays ~10k entries and replays in seconds). Keys: parent `<county>-<jobId>`,
chunks `<county>-<jobId>-c<N>`; `county` and `jobId` also arrive as payload fields so
artifact paths stay `<county>/<jobId>`-scoped:

```ts
import * as restate from "@restatedev/restate-sdk";
import { RestatePromise, TerminalError } from "@restatedev/restate-sdk";
import { parcel } from "./parcel";
import { loader } from "./loader";
import { permitFeed } from "./permit-harvest";
import { buildSeedIndex, readSeedBatch } from "./lib/storage"; // fs helpers over DATA_DIR
                                          // (dataPath rejects absolute paths + traversal)

type RunReq = { county: string; jobId: string;
                seedPath: string; // DATA_DIR-relative, e.g. "seeds/lee.csv"
                chunkSize: number; batchSize: number; window: number };

export const countyIngest = restate.workflow({
  name: "CountyIngest",
  handlers: {
    run: async (ctx: restate.WorkflowContext, req: RunReq) => {
      // key "<county>-<jobId>" (or "…-r2" for a redrive pass) makes the run exactly-once
      const slug = /^[a-z0-9-]+$/;
      if (!slug.test(req.county) || !slug.test(req.jobId) ||
          ![req.chunkSize, req.batchSize, req.window].every((n) => Number.isInteger(n) && n > 0))
        throw new TerminalError("invalid run request"); // invocation-level: never retried
      const base = `${req.county}-${req.jobId}`;
      if (ctx.key !== base && !new RegExp(`^${base}-r[1-9][0-9]*$`).test(ctx.key))
        throw new TerminalError("workflow key must be <county>-<jobId>[-rN]");
      // Index once: writes a byte-offset index next to the seed and returns the row
      // count. readSeedBatch then SEEKS via the index — O(1) per batch, no rescans (the
      // old pipeline re-streamed a 282 MiB seed from row 1 on every wakeup).
      const total = await ctx.run("index-seed", () => buildSeedIndex(req.seedPath));
      const chunks = Math.ceil(total / req.chunkSize); // chunkSize ~10-20k rows
      ctx.set("chunks", chunks); // total, for monitoring's chunksDone ÷ chunks
      for (let c = 0; c < chunks; c++) {
        // Child keys derive from the PARENT key: a redrive parent (-r2) spawns fresh
        // children instead of hitting the original run's already-completed chunk keys.
        await ctx.workflowClient(ingestChunk, `${ctx.key}-c${c}`)
          .run({ ...req, offset: c * req.chunkSize });
        ctx.set("chunksDone", c + 1); // progress, visible in UI / restate sql
      }
      // Appraisal dispatch done. Hand permits to the BOUNDED permit feeder — never one
      // send per parcel from Parcel.process: that would queue every eligible parcel at
      // once, recreating the whole-county dump this design exists to prevent.
      ctx.workflowSendClient(permitFeed, `${ctx.key}-permits`)
        .run({ county: req.county, jobId: req.jobId });
      return { county: req.county, jobId: req.jobId, total, chunks };
    },
  },
});

export const ingestChunk = restate.workflow({
  name: "IngestChunk",
  handlers: {
    run: async (ctx: restate.WorkflowContext, req: RunReq & { offset: number }) => {
      for (let done = 0; done < req.chunkSize; ) {
        const rows = await ctx.run("read-batch", () => readSeedBatch(
          req.seedPath, req.offset + done, Math.min(req.batchSize, req.chunkSize - done)));
        if (rows.length === 0) break; // seed exhausted
        for (let i = 0; i < rows.length; i += req.window) {
          const slice = rows.slice(i, i + req.window);
          await RestatePromise.all(slice.map((row) =>
            ctx.serviceClient(parcel).process(
              { ...row, county: req.county, jobId: req.jobId }))); // row carries parcel_id;
              // canonical fields spread LAST so a CSV column cannot override them
        }
        done += rows.length;
      }
      // Hand this chunk's artifacts to the county Loader — the single-writer incremental
      // merge; this send is what advances the Loader watermark (no timer needed).
      // Loader derives artifactPrefix + jurisdictionKey from ITS OBJECT KEY + jobId —
      // a payload cannot point a lee-keyed Loader at another county's data (pattern 8).
      ctx.objectSendClient(loader, req.county).load({
        jobId: req.jobId, tracks: ["appraisal"], step: "incremental",
      });
      return {};
    },
  },
});
```

`services/parcel.ts` — per-parcel unit of work, every step a `ctx.run`. The canonical
payload field is `parcel_id` (from the seed CSV); the `<folio>` path segment is its
sanitized form, `safeKeyPart(parcel_id)`:

```ts
import * as restate from "@restatedev/restate-sdk";
// lib/storage: dataPath(...parts), exists(path); writes go tmp-file → rename, so an
// interrupted ctx.run never leaves a half-written artifact.
import { dataPath, exists, removeIfExists, safeKeyPart } from "./lib/storage";
import { capture, transform, validate, upsertParcelRow, writeEligibility,
         writeDead, writeInvalid, writeReady, type SeedRow } from "./lib/parcel-steps";
import { countyGate } from "./lib/limits";

export const parcel = restate.service({
  name: "Parcel",
  handlers: {
    process: async (ctx: restate.Context, p: SeedRow & { county: string; jobId: string }) => {
      const dir = dataPath("artifacts", "appraisal", p.county, p.jobId, safeKeyPart(p.parcel_id));
      // 1. Raw capture (elephant-cli prepare / browser flow). Deterministic path,
      //    skip-existing → re-runs never re-scrape. A gone parcel records dead.json below.
      const captured = await ctx.run("capture", async () => {
        if (await exists(`${dir}/capture.zip`)) return true;
        return countyGate("prepare", p.county, 8)(() =>
          capture(p, `${dir}/capture.zip`)); // false ⇒ gone
      });
      if (!captured) {
        // DEAD: record + return. Never THROW for a per-parcel condition — it would
        // propagate through the chunk's RestatePromise.all and fail the whole run.
        await ctx.run("record-dead", async () => {
          await removeIfExists(`${dir}/ready.json`); // no longer loadable
          await writeDead(`${dir}/dead.json`, "gone-at-source");
        });
        return { parcel_id: p.parcel_id, status: "dead" };
      }
      // 2. Transform v2 from the stored raw capture — never from a live page. transform()
      //    writes transformed.meta.json (capture hash + transform version) and skips only
      //    when BOTH match — so a fixed transform regenerates stale output on re-runs.
      await ctx.run("transform", () => countyGate("transform", p.county, 16)(() =>
        transform({ county: p.county, src: `${dir}/capture.zip`,
                    dest: `${dir}/transformed.zip` })));
      // 3. Validate, fail closed: invalid parcels are recorded and EXCLUDED, never loaded.
      const v = await ctx.run("validate", () => validate(`${dir}/transformed.zip`));
      if (!v.valid) {
        await ctx.run("record-invalid", async () => {
          await removeIfExists(`${dir}/ready.json`); // fail-closed: not loadable
          await writeInvalid(`${dir}/invalid.json`, v.errors);
        });
        return { parcel_id: p.parcel_id, status: "invalid", errors: v.errors };
      }
      // Status artifacts reflect CURRENT state: a pass clears BOTH stale markers
      // (a parcel once dead or invalid that now validates is neither).
      await ctx.run("clear-stale-markers", async () => {
        await removeIfExists(`${dir}/invalid.json`);
        await removeIfExists(`${dir}/dead.json`);
      });
      // 4. Idempotent DB upsert + eligibility artifact. writeEligibility stamps the
      //    resolved policy fingerprint and recomputes when the policy changed (e.g.
      //    __NONE__ → __ALL__) — a same-job redrive must not trust stale eligibility.
      await ctx.run("upsert", () => upsertParcelRow(p, dir)); // ON CONFLICT DO UPDATE
      const eligibility = await ctx.run("eligibility", () =>
        writeEligibility(`${dir}/eligibility.json`, `${dir}/transformed.zip`, p));
      // Loadable = ready.json present. Written ONLY here; removed on dead/invalid — the
      // loader and pre-load validation enumerate ready markers, never raw transformed.zip.
      await ctx.run("mark-ready", () => writeReady(`${dir}/ready.json`));
      // NOTE: no permit send here. Permits are dispatched by the bounded PermitFeed
      // feeder after appraisal dispatch — one send per parcel from here would queue the
      // whole eligible county at once (see CountyIngest and pattern 1).
      return { parcel_id: p.parcel_id, status: "ok", eligibility };
    },
  },
});
```

Virtual objects follow the same shape with `restate.object({ name, handlers })` and a
`restate.ObjectContext`. Patterns 8–10 below define the `Loader` and `Publish`
*contracts* — behavioral specs you author the same way, not code that already exists.
Permit portal modules themselves live in `county-permit-adapter`; `PermitHarvest` just
routes to them. `PermitFeed` is the permit-side twin of the appraisal feeder — author it
from the `CountyIngest`/`IngestChunk` skeleton above with this contract. Keys derive
from the parent: `PermitFeed` = `<CountyIngest key>-permits` (a redrive pass feeds
`…-r2-permits`, never colliding with the first pass); children = `<PermitFeed key>-c<N>`.
Request: `{county, jobId, chunkSize?, batchSize?, window?}` (defaults 10000/100/25;
chunk children add `offset`). It scans eligibility artifacts (`eligible: true`) into an
eligible-list index (`data/artifacts/permits/<county>/<jobId>/eligible.idx`) — rebuilt
atomically on EVERY pass and stamped with the eligibility-policy fingerprint, so a
policy change never reuses a stale index; a malformed `eligibility.json` is recorded
and skipped, never thrown — one bad manifest must not poison the feeder. Track
`chunks`/`chunksDone` state exactly like `CountyIngest`; each chunk dispatches
`PermitHarvest.harvestParcel` in bounded windows and, on completion (per chunk, not per
window), submits `Loader.load({ jobId, tracks: ["permits"], step: "incremental" })`.

**Lib contracts** — author these signatures before the first run (the skeletons above
import them; `npm run typecheck` must pass):

```ts
// lib/storage.ts
dataPath(...parts: string[]): string   // joins under DATA_DIR; rejects absolute + traversal
exists(path: string): Promise<boolean>
removeIfExists(path: string): Promise<void>
buildSeedIndex(seedPath: string): Promise<number>  // writes <seed>.idx (byte offsets); returns row count
readSeedBatch(seedPath: string, offset: number, limit: number): Promise<SeedRow[]> // seeks via index
safeKeyPart(s: string): string         // fs-safe; collision-safe (suffix a short hash when chars drop)

// lib/parcel-steps.ts — canonical seed header: parcel_id REQUIRED; source_identifier
// falls back to parcel_id when absent; extra columns flow through untouched.
// buildSeedIndex validates the header. SeedRow =
//   { parcel_id: string; source_identifier?: string; situs_address?: string;
//     [column: string]: string | undefined }
capture(p, dest: string): Promise<boolean>   // elephant-cli prepare / browser flow; false = gone
transform(req: { county: string; src: string; dest: string }): Promise<void>
  // resolves the county's v2 handler package transforms/<county>/transform-v2.zip (root
  // handler.js — built per transform-v2-builder from Counties-trasform-scripts sources);
  // writes transformed.meta.json (capture hash + package hash/version); skips iff BOTH match.
  // REMOVES ready.json before regenerating — a replacement is never loadable until revalidated
validate(path: string): Promise<{ valid: boolean; errors?: unknown }>  // elephant-cli validate
upsertParcelRow(p, dir: string): Promise<void>       // single-row ON CONFLICT DO UPDATE
writeEligibility(dest: string, transformedPath: string, p): Promise<{ eligible: boolean }>
  // reads usage type FROM THE TRANSFORMED OUTPUT (policy needs transformed data, not the
  // seed row); persists { eligible, usageType, policyFingerprint }; county env suffix via envPart
writeDead(dest: string, reason: string): Promise<void>
writeInvalid(dest: string, errors: unknown): Promise<void>
writeReady(dest: string): Promise<void>
  // loadability marker; records the validated transform hash — Loader loads a parcel only
  // when the ready hash matches transformed.meta.json (a regenerated zip is not loadable)
```

## Pattern library

The distilled lessons of a production county pipeline. Apply them as written.

**1. Backpressure feeder.** Never dispatch a whole county at once — the previous pipeline
once dumped 516k messages into a queue, exceeding retention and losing all flow control.
The `CountyIngest`/`IngestChunk` pair above IS the fix: `window` (25–100) bounds
in-flight calls, per-chunk child workflows bound journal growth, and replay resumes
mid-chunk. Crash/reboot resumes mid-county; no checkpoint files, no watchdog timers, no
re-streaming a 282 MiB seed from row 1 on every wakeup.

**2. Layered concurrency.** Three layers: admission window (feeder) → per-stage/portal
semaphores in the services process → in-process pools (browser contexts). The Restate
server does NOT enforce per-service concurrency caps on this stack (server-side flow
control is a 1.7 preview behind experimental flags — adopt it once stable); the enforced
cap is an in-process gate with limits from env:

```ts
// lib/limits.ts — one semaphore per named stage/portal, cap from CONCURRENCY_<NAME>
import pLimit from "p-limit";
const gates: Record<string, ReturnType<typeof pLimit>> = {};
export const envPart = (s: string) => s.toUpperCase().replace(/[^A-Z0-9]+/g, "_");
export const gate = (name: string, fallback: number) => {
  const n = Number(process.env[`CONCURRENCY_${envPart(name)}`]);
  return (gates[name] ??= pLimit(Number.isInteger(n) && n >= 1 ? n : Math.max(1, fallback)));
};
// countyGate: county-scoped cap when set, else the bare stage cap — so the skeleton
// honours CONCURRENCY_PREPARE_PALM_BEACH without edits, and falls back to CONCURRENCY_PREPARE.
export const countyGate = (stage: string, county: string, fallback: number) =>
  process.env[`CONCURRENCY_${envPart(stage)}_${envPart(county)}`]
    ? gate(`${stage}_${county}`, fallback) : gate(stage, fallback);
// empty/0/garbage env values fall back — a gate never throws or silently blocks forever;
// envPart makes hyphenated counties safe: prepare_palm-beach → CONCURRENCY_PREPARE_PALM_BEACH

// usage inside a handler step (canonical gate names: prepare, transform, permit_<vendor>):
await ctx.run("capture", () => gate("prepare", 8)(() => capture(p, dest)));
await ctx.run("harvest", () => gate("permit_accela", 2)(() => harvest(p)));
```

Portal politeness numbers: prepare ~50 after burn-in, transform ~100, permit portals
start at 2 — Accela degrades above ~4. To change a cap: edit `.env` and restart the
services process — safe mid-run, in-flight invocations resume from their journals. Ramp
one step at a time; watch error rates in the UI after every step. Each feeder's `window`
(appraisal and permit sides alike) bounds its in-flight work, so gates only shape short local queues, never unbounded
ones. Running two counties concurrently? Scope the gate name per county —
``gate(`prepare_${county}`, 8)`` → `CONCURRENCY_PREPARE_PALM_BEACH` (envPart normalizes
the hyphenated slug); the bare names imply one county at a time.

**3. Deterministic keys + skip-existing resume.** Artifact paths derive from
county/jobId/folio only (`safeKeyPart()` sanitization); every writer checks before it
writes. Re-running anything is safe and cheap — resume is a property of the paths, not a
separate redrive procedure. Redrive passes therefore reuse the SAME `jobId` payload
under a NEW workflow key (`<county>-<jobId>-r2`): the key gives the pass exactly-once,
the unchanged jobId keeps artifacts in the same namespace so skip-existing applies.

**4. Idempotent side effects in `ctx.run`.** A step interrupted mid-flight re-executes
from its start. File writes: deterministic path, atomic tmp+rename. DB: `ON CONFLICT DO
UPDATE`. External calls:
check-then-act or natural idempotency. In the old pipeline, at-least-once delivery times
non-idempotent completion callbacks produced an entire class of dead-token churn bugs;
this rule makes the class impossible.

**5. DEAD vs RETRYABLE taxonomy.** Permanent per-item conditions (404 page, parcel gone,
selector permanently absent) are RECORDED — `dead.json` next to the artifacts plus a
`status: "dead"` return — and the handler returns normally. Never throw for a per-item
condition: a thrown `TerminalError` propagates through the chunk's `RestatePromise.all`
and fails the whole run. Reserve `TerminalError` for invocation-level permanent errors
(invalid payload, broken config). Transient conditions (timeouts, 5xx, nav failures)
throw ordinary errors — retried with backoff, pausing at max attempts. Disambiguate an
HTTP 500 with a couple of unloaded probes before classifying. See the error taxonomy
section below.

**6. Claim-check.** Files go to `data/`; journals and object state hold only paths and
small JSON — never file contents. Restate caps payload entries at 32 MiB — never put
captures or zips in workflow state. The old pipeline blurred artifact store, state store,
and signalling channel into one storage layer; here the filesystem plays only the
artifact role.

**7. Fail-closed validation gate.** Every parcel passes `elephant-cli validate` before
its row is loaded or permits are enqueued. A parcel that fails is recorded and excluded
— never silently loaded. The mechanism: loaders and pre-load validation enumerate
`ready.json` markers (written only after validation passes, removed on dead/invalid) —
never raw `transformed.zip` files, which exist before validation runs. Status
transitions are ORDERED: `transform()` removes `ready.json` before regenerating (a
replacement is unloadable until revalidated); `ready.json` records the validated
transform hash and the Loader loads only on hash match; `ok → invalid/dead` leaves a
tombstone the Loader reconciles into a DB deletion or status downgrade; a later pass
that validates clears BOTH stale markers. Test all four transitions
(`ok→invalid`, `ok→dead`, `invalid→ok`, `dead→ok`). Origin: a branch
of the old pipeline skipped validation and unvalidated data reached the DB. See
`validate-county-transform`.

**8. Single-writer per county (Virtual Object).** Parallel bulk merges into DB parent
tables deadlock. Route ALL bulk loads for a county through `Loader.load` (object keyed by
`<county>`) — the object's per-key serialization replaces advisory locks and serial-task
constraints. Ownership split: `Parcel.process` keeps its per-parcel single-row upsert
(deadlock-safe); `Loader` owns every MULTI-row bulk merge, clear, and reload. The object
key is the identity: `Loader` derives `dbCounty = ctx.key.replace(/-/g, "_")`,
`jurisdictionKey = dbCounty + "_appraiser"`, and the job artifact prefix from key +
payload `jobId` — a payload-supplied value that differs from the derived one is rejected
with `TerminalError`, so a lee-keyed invocation can never clear or load another county.
`Loader` owns the permits track too: `PermitFeed` submits batched permit merges per
completed chunk (`tracks: ["permits"]`); harvesters write artifacts and status only,
never merge inline. Watermarks are content-aware: `watermark_<track>` state tracks
merged (path, artifact-hash) pairs — the hash index lives on disk under
`$DATA_DIR/staging/loader/<county>/<jobId>/` (claim-check; state stays small) — so an
in-place redrive that regenerates `transformed.zip` gets re-merged; a path-only
watermark would silently skip corrections. The incremental merge also consumes
invalid/dead TOMBSTONES — removing or downgrading previously loaded rows; without that,
a parcel that went invalid after loading lives on in the DB and the published data.
Loader steps are long: raise its timeouts per authoring rule 3. The same primitive makes `Publish` a per-county singleton for free. Merge
details: `query-db-loading-matching`.

**9. Human approval gate as durable state.** PII review: `Publish` dry-runs until
`Publish/<county>/approve` has been called once; `approve()` flips a durable flag in
object state. No external parameter store, no "missing param = dry-run" convention —
the gate is explicit state you can read in the UI.

**10. Self-scheduling loop.** Recurring work (the incremental publish tick) is a virtual
object handler that re-schedules itself with a delayed send —
`ctx.objectSendClient(publish, county).tick({}, restate.rpc.sendOpts({ delay: { minutes: 15 } }))`
— or waits with `ctx.sleep`. One tick per county runs the full publish sequence in
order: consolidation export/upload first (writes `manifest.json`), then the query-table
export/publish (which reads that manifest) — a single loop, not two competing ones.
`requestPublish()` sets pending AND arms the first tick when none is scheduled (persist
a `tickScheduled` flag; every tick re-arms exactly one successor) — a fresh county must
never sit pending forever. State machine: an unapproved tick dry-runs ONCE per content
watermark (persist `lastDryRunWatermark`), LEAVES `pending = true`, and stops re-arming
until `approve()` or a newer `requestPublish()` — never rebuild a multi-GB export every
15 minutes while waiting for a human. `approve()` sets approved and arms an immediate
tick when pending; `pending` clears only after a successful APPROVED publication. Replaces cron rules, poll loops, and the
stale-checkpoint watchdog — which, in its naive no-cooldown form, once piled ~150
duplicate feeder invocations that deadlocked the worker.

**11. Chunked fan-out.** Never run a whole county through one invocation: `window` bounds
concurrency but NOT journal length — 516k rows in a single journal is >1M entries,
replayed in full on every crash. The `IngestChunk` children in the skeleton bound both.
For independent bulk jobs (enrichment batches), same move: per-chunk workflows keyed by
chunk id.

**12. Geo-gate first.** Before debugging any scrape failure: `curl -s ipinfo.io/country`
must print `US` — county portals geo-block, and everything now runs on your machine.
Get US egress (VPN/proxy) before touching code. Politeness delays and proxy URLs are
worker config, not infra.

**13. Flat listing.** When reconciling artifact counts, one `find` sweep over the job
directory beats per-parcel stat-in-a-loop — the same ~80× lesson learned reconciling the
old pipeline, in filesystem form.
`find data/artifacts/appraisal/<county>/<jobId> -name transformed.zip | wc -l`.

**14. Raw-first capture.** Always store the raw capture next to the extraction so
re-transform never re-scrapes. Transform reads `capture.zip`, never a live page.

**15. 48-hour source-feasibility gate.** Probe source throughput before any full run
(pilot of ~100 parcels; measure latency, failure rate, safe concurrency). If full
acquisition exceeds 48h, stop and ask: download anyway / ingest-only / runtime retrieval
from the owning app. See `county-permit-adapter` for the permit-portal variant.

## Error taxonomy

- **Permanent, per-item (dead parcels)** — record and return per pattern 5; never throw,
  so one dead parcel cannot reject the sibling parcels awaited in the same chunk.
- **`TerminalError`** — permanent, invocation-level. Not retried; the invocation fails.
  Use for: invalid request payloads, broken configuration — cases where the invocation
  itself, not a data item, is unfixable by retry.
- **Any other thrown error** — retryable. Restate retries with exponential backoff and,
  at max attempts, **pauses** the invocation instead of dropping it. The stock 1.7
  server's default policy retries ~70 times with exponential backoff, then pauses
  (`on-max-attempts = pause`) — review/tune `default-retry-policy` (or per-service retry
  options via UI/CLI/SDK) during bootstrap so misclassified permanent failures pause on
  your intended schedule; an explicitly UNSET policy means unlimited retries and nothing
  ever pauses. Paused invocations
  are visible in the UI (:9070) with the full journal and last error: inspect, fix the
  WORLD (egress, portal, disk), then resume — resume replays onto the same deployment.
  For CODE fixes: `resume --deployment latest` only helps when a genuinely distinct
  deployment exists; on this single-endpoint local topology, prefer cancelling the
  paused invocations and re-running them as a redrive pass (pattern 3) on the new code,
  or an in-place replay-compatible fix per authoring rule 2. This replaces every
  DLQ-inspect-and-redrive procedure.
- **Never gate completion on an exact count.** Some parcels are legitimately dead at the
  source; `assert loaded == seedTotal` produces an infinite retry loop (the old pipeline
  burned ~10 h per attempt on exactly this). Gate on `loaded >= achievable`, where
  achievable = seed − dead − current-invalid, and reconcile the same identity:
  seed = loaded + dead + current-invalid ("current" because a stale `invalid.json` is
  cleared when a later validation passes).

## Operate & debug quick reference

```bash
docker compose up -d                      # restate + postgres
npm run dev                               # services on :9080 (tsx watch services/app.ts)
restate deployments register http://host.docker.internal:9080   # --force in dev only

# start a run (fire-and-forget)
curl localhost:8080/restate/send/CountyIngest/<county>-<jobId>/run \
  --json '{"county":"lee","jobId":"2026q3","seedPath":"seeds/lee.csv","chunkSize":10000,"batchSize":100,"window":25}'

# approve publish (durable PII gate; --json makes this a POST)
curl localhost:8080/restate/call/Publish/<county>/approve --json '{}'

# inspect
restate invocations list
restate invocations describe <id>         # journal, current step, last error
restate invocations resume <id>           # after fixing a paused invocation
restate invocations cancel <id>           # graceful; kill <id> as last resort
restate sql "SELECT id, target, status FROM sys_invocation WHERE status != 'completed'"
```

- **Web UI `http://localhost:9070`**: invocations with live journals, workflow/object
  state (e.g. `CountyIngest` chunksDone, `Publish` approved flag), paused invocations
  with their error, and per-service configuration (retries and the inactivity/abort
  timeouts from authoring rule 3 — not concurrency).
- **Concurrency caps live in `.env`** (`CONCURRENCY_*`, pattern 2): edit and restart the
  services process — safe mid-run, invocations resume from their journals. Use the UI to
  watch error rates while ramping; it does not tune caps on this stack.
- Counts for reconciliation: `find … | wc -l` over `data/artifacts` (pattern 13) and
  `docker compose exec postgres psql -U postgres elephant -c "..."`.
- Run operations end-to-end (pilot, ramp, wrap-up): `county-ingest-run`. Status and ETA
  reporting: `monitoring-county-ingestion`.
