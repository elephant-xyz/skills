---
name: bootstrap-oracle-infra
description: Verify and bootstrap the AWS infrastructure required by the oracle-node county ingestion pipeline - main stack, permit-harvest stack, seeds bucket, secrets, and Neon query DB. Use when starting county onboarding, when a deploy/enqueue script fails with missing stack outputs or AccessDenied, or when setting up oracle-node in a fresh AWS account.
metadata:
  author: elephant-xyz
---

# Bootstrap Oracle Infra

Work from a checkout of `oracle-node` (branch with property-first ingest support). Sibling
checkout of `elephant-query-db` is needed for Neon access.

All AWS commands require `AWS_PROFILE` and `AWS_REGION` to be set. Never hardcode account IDs.

## Verification checklist

Run these checks first; only bootstrap what is missing.

```bash
# 1. Main workflow stack (prepare/transform/state machine)
aws cloudformation describe-stacks --stack-name "${STACK_NAME:-elephant-oracle-node}" \
  --query 'Stacks[0].Outputs' --output table

# 2. Permit-harvest stack (permit + property-first queues, worker)
aws cloudformation describe-stacks --stack-name elephant-permit-harvest \
  --query 'Stacks[0].Outputs' --output table

# 3. Seeds bucket (county seed CSVs live here)
aws s3 ls s3://counties-seeds/

# 4. Environment bucket (from main stack output EnvironmentBucketName)

# 5. Neon DATABASE_URL secret consumed by the permit worker
aws secretsmanager list-secrets \
  --query "SecretList[?contains(Name, 'query') || contains(Name, 'database')].Name"

# 6. Neon DB reachable
cd ../elephant-query-db && npx tsx -e "import postgres from 'postgres'; const sql=postgres(process.env.DATABASE_URL); const r=await sql\`select 1 as ok\`; console.log(r); await sql.end()"
```

## Bootstrapping

### Main stack

Follow `oracle-node/README.md`. For archive-only ingestion (no minting), the blockchain
secrets are still required by the template but unused at runtime; set the documented
`ELEPHANT_*` env vars and run:

```bash
./scripts/deploy-infra.sh
```

Critical post-deploy setting: keep the budget kill switch off, or a daily budget alarm will
silently disable event source mappings mid-run (this happened during the Lee run):

- Template/param `EmergencyStopEnabled=false` must be set (the deploy script pins it).

### Permit-harvest stack

```bash
aws cloudformation deploy \
  --template-file permit-harvest/template.yaml \
  --stack-name elephant-permit-harvest \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    EnvironmentBucketName=<from main stack output> \
    SourceSeedBucketName=counties-seeds \
    QueryDatabaseUrlSecretArn=<secret arn> \
    PermitHarvestMaximumConcurrency=2 \
    PropertyFirstPermitMaximumConcurrency=10
```

Worker code updates are shipped by zipping the lambda dir to
`s3://<env-bucket>/deployments/permit-harvest-worker/…zip` and calling
`aws lambda update-function-code`.

`SourceSeedBucketName` matters: without it the seed feeder gets `AccessDenied` reading
`counties-seeds`.

### Per-county prepare queue

Each county gets its own prepare queue so throughput can be tuned per county portal:

```bash
./scripts/create-county-prepare-queue.sh <county_key>   # e.g. lee, palm_beach
```

### Neon query DB

Provisioning runbook: `../elephant-query-db/docs/vercel-neon-query-db.md` (Vercel Neon
integration, project `elephant-query-db`). After provisioning, store `DATABASE_URL` in
Secrets Manager and pass its ARN as `QueryDatabaseUrlSecretArn`.

### Transform scripts sync

County transform scripts come from `github.com/elephant-xyz/Counties-trasform-scripts`,
staged to S3 and resolved at runtime by the transform worker's scripts-manager. Deploy with
`UPLOAD_TRANSFORMS=true` or use the GitHub sync function; a GitHub token secret must exist.

## Known constraints

- SQS event-source `MaximumConcurrency` must be ≤ Lambda reserved concurrency, or
  messages churn without progress.
- Concurrency is tuned live via `aws lambda update-event-source-mapping --scaling-config
  MaximumConcurrency=N`, not via template redeploys.
- elephant-cli is installed from GitHub (npm publishing has been unreliable); see
  `oracle-node/package.json` for the pinned ref.
