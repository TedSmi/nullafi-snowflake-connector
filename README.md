# nullafi-snowflake-connector

A Snowflake-native connector that routes data through Nullafi for sensitive-data
detection and protection before it continues through a pipeline.

**Status:** Phase 6 clean-environment validation passed. The reusable installer
provisioned successfully in a fresh Snowflake database/schema, processed a
synthetic row through Nullafi, completed an idle run without an API call, and
ran successfully through both scheduled-task and monitoring paths. The tasks
were suspended after validation. Release steps and Phase 2 secret-rotation and
query-history closeout remain.

## Phase 6: Reusable connector

Use [`snowflake/phase6_setup.sql`](snowflake/phase6_setup.sql) for a new
installation. It is the supported entry point for a real source table; the
earlier phase scripts remain documented POCs and should not be mixed into the
same schema.

The parameter block at the top of the script supplies the source table, stable
source key, JSON array of source columns to scan, output table, Nullafi
namespace, task warehouse, and schedule. It creates the secret, network rule,
external-access integration, config table, stream, durable ID-only queue,
output/error/run-log tables, processor, monitor, and suspended tasks.

```
source table insert
       |
 Snowflake stream -> durable ID-only queue -> Nullafi /scan
       |                                        |
       +------------------------------> configured output table
                                             |
                                    run/error/task-failure monitoring
```

The connector is insert-triggered: updates do not rescan an existing source
key, and a queued row deleted before processing is recorded as skipped. It
does not alter the source table or add connector status columns to it. Results
are idempotently merged by configuration, source key, and column.

### Validation status

Clean-environment validation used a fresh Snowflake database with separate
source, connector, and protected-output schemas. The installer accepted the
configured `ARRAY` scan-column mapping, its preflight validation passed, and a
new synthetic three-field row produced one successful API batch and three
output rows with no dead-letter entries. The next manual invocation selected
zero rows and made zero API calls. Finally, a second synthetic row was
successfully processed through `NULLAFI_CONNECTOR_PROCESS_TASK`; its task
history reported `SUCCEEDED`, and both the task-failure log and pipeline-alert
view were empty. The validation tasks were then suspended to avoid idle
warehouse use.

### Install and operate

1. Create a new connector schema and choose a role with the privileges below.
2. Open the Phase 6 script in a private worksheet, set its context and replace
   the parameter-block examples. Replace the API-key placeholder only in that
   private worksheet.
3. Run the whole script. Its preflight procedure verifies the source table and
   every configured key/scan column before it creates the tasks.
4. Inspect `NULLAFI_CONNECTOR_CONFIG`, then make the first controlled call:

   ```sql
   CALL NULLAFI_CONNECTOR_PROCESS();
   SELECT * FROM NULLAFI_CONNECTOR_RUN_LOG ORDER BY STARTED_AT DESC;
   ```

5. Once that succeeds, enable scheduled operation:

   ```sql
   ALTER TASK NULLAFI_CONNECTOR_PROCESS_TASK RESUME;
   ALTER TASK NULLAFI_CONNECTOR_MONITOR_TASK RESUME;
   ```

The setup role needs `USAGE` on the connector database/schema and source and
output locations; `CREATE NETWORK RULE`, `CREATE SECRET`, `CREATE PROCEDURE`,
`CREATE TABLE`, `CREATE STREAM`, `CREATE TASK`, and (account-level) `CREATE
INTEGRATION`. The task owner also needs `USAGE` on the chosen warehouse. Grant
the connector owner `SELECT` on the source table and `CREATE`/DML privileges in
the output schema. Snowflake's external-access feature and Python packages
`requests` and `snowflake-snowpark-python` must be available.

### Configuration and troubleshooting

- Identifiers are intentionally limited to unquoted one-, two-, or three-part
  names. This makes the dynamic SQL safe and gives a clear error for quoted or
  malformed mappings.
- `SCAN_COLUMNS` must be a non-empty JSON array; its entries must exist on the
  source table, be unique, and exclude the source key.
- `MAX_FIELD_CHARACTERS` and `MAX_VALUES_PER_REQUEST` default to conservative,
  configurable limits because Nullafi's production limits are not measured.
- `STORE_RAW_RESPONSES` defaults to `FALSE`; leave it there unless temporary
  diagnostics justify storing responses that might contain sensitive data.
- A `401`/`403` is generally a missing or incorrectly scoped Nullafi API key;
  an external-access error usually means the account lacks the required feature
  or privilege; a preflight error identifies the bad table or column mapping.

Known limitations: only unquoted identifiers and `INSERT_ONLY` change handling
are currently supported. A source key must be stable and unique. Entity types
are not written because they are absent from the confirmed `/scan` response.
The installer creates/replaces connector-owned objects, so review the script
before rerunning it in a populated connector schema.

### Roadmap

A Snowflake Native App is a potential future packaging option. It is explicitly
out of scope for this release.

## Phase 5: Scheduled Automation

`snowflake/phase5_automation.sql` adds two user-managed-warehouse tasks:
`NULLAFI_PHASE5_PROCESS_TASK` calls `NULLAFI_PROCESS_BATCH()` every five
minutes, and `NULLAFI_PHASE5_MONITOR_TASK` records failed processing-task runs
in `NULLAFI_PHASE5_TASK_FAILURE_LOG`. Recoverable API and row failures remain
visible through `NULLAFI_PHASE5_PIPELINE_ALERTS`, which reads the existing run
log.

Before running the script, complete Phases 2–4 in the same schema and replace
`<YOUR_WAREHOUSE>` with a warehouse the task-owner role can use. That role also
needs `CREATE TASK` in the schema, `USAGE` on the warehouse, and the privileges
already required to call the pipeline procedure. The script resumes both tasks;
suspend them before maintenance:

```sql
ALTER TASK NULLAFI_PHASE5_PROCESS_TASK SUSPEND;
ALTER TASK NULLAFI_PHASE5_MONITOR_TASK SUSPEND;
```

To test or inspect automation without the Snowflake UI, use the `EXECUTE TASK`,
`TASK_HISTORY`, run-log, and failure-log queries included at the end of the
script. The task automatically suspends after three consecutive task-level
failures; recoverable Nullafi failures do not fail the task, so monitor the
pipeline-alert view as well.

Live validation confirmed that the scheduled task processed one newly inserted
synthetic row and that the next idle invocation processed zero rows. A safe
invalid-argument test then produced a task failure that
`NULLAFI_PHASE5_MONITOR_TASK` persisted to
`NULLAFI_PHASE5_TASK_FAILURE_LOG`. The tasks were suspended after validation;
resume both only when automated processing is wanted.

## Phase 4: Incremental Processing with Streams

`snowflake/phase3_batch_pipeline.sql` now creates
`NULLAFI_PHASE4_INPUT_STREAM` and a durable, ID-only
`NULLAFI_PHASE4_WORK_QUEUE`. Each invocation first consumes the stream through
a `MERGE` into that queue, then sends only queued inserts to Nullafi. This is
important because a stream read by `SELECT` alone does not advance its offset.
The queue also prevents unprocessed work from being lost when an invocation is
limited by `MAX_ROWS` or fails after the stream is consumed.

The sample uses insert-triggered processing:

- An insert is scanned once.
- An update does not trigger a rescan; a new record ID is required to scan a
  changed value in this POC.
- A delete does not delete historical output. If a queued record disappears
  before scanning, it is marked `SKIPPED_SOURCE_DELETED` and is not sent to
  Nullafi.

The SQL script includes a new-row test that inserts `cust_004`, followed by an
idle-run test. The first call should select one row; the next should select
zero. Run it after the initial Phase 3 validation in the same private
worksheet.

## Phase 3: Batch Pipeline

`snowflake/phase3_batch_pipeline.sql` implements the first end-to-end,
Snowflake-native pipeline: synthetic input rows are grouped into conservative
multi-value `/scan` requests, then results are written to an output table.
Failures are written to a dead-letter table, and run metrics go to a run-log
table.

Live validation passed with the synthetic dataset: the happy path processed all
three records, a deliberately malformed endpoint produced recoverable
dead-letter entries, and a normal rerun selected no already-processed rows.
After configuring Nullafi's application/rule/obfuscation policy, the Phase 2
SSN smoke test returned `changed: true`; Phase 3 therefore records protected
SSNs as `SUCCESS` with `VALUE_CHANGED = TRUE`.

The script is intentionally a sample implementation, with fixed
`NULLAFI_PHASE3_*` object names and the five fields in Phase 1's synthetic
dataset. For configuration-driven production setup, use the Phase 6 installer
above instead. The sample requires the secret and external-access integration
created by Phase 2.

Run it from a private Snowflake worksheet after completing Phase 2:

```sql
-- Run the complete snowflake/phase3_batch_pipeline.sql script first.
CALL NULLAFI_PROCESS_BATCH();

SELECT PROCESSING_STATUS, COUNT(*)
FROM NULLAFI_PHASE3_SAMPLE_INPUT
GROUP BY PROCESSING_STATUS;
```

The procedure processes `PENDING` rows by default. Its output writes use a
`MERGE` keyed by source record and field, so the normal second run selects no
already-processed records and cannot duplicate results. To retry only failed
records, call `CALL NULLAFI_PROCESS_BATCH(100, TRUE);`.

Because Nullafi's real batch and payload limits remain unmeasured, the current
implementation limits each value to 1,000 characters and each outbound request
to 20 field values. Oversized values and failed API batches go to
`NULLAFI_PHASE3_ERROR_LOG`; they do not stop unrelated batches.

## Phase 2: Snowflake Connectivity

Phase 2 proves that a Python stored procedure can reach Nullafi through
Snowflake external network access. The implementation lives in
`snowflake/phase2_connectivity.sql` and the runbook lives in `SETUP.md`.

Live validation succeeded after upgrading the Snowflake account: the procedure
returned `ok: true`, HTTP `200`, and the expected JSON response. This proves
Snowflake egress, secret retrieval, and Nullafi authentication. After the
Nullafi policy was configured, the synthetic SSN test also returned
`changed: true`, proving that obfuscation is applied.

### What Phase 2 Added

- A Snowflake `NETWORK RULE` scoped to `openflow.nullafi.net`.
- A Snowflake `GENERIC_STRING` secret for the Nullafi API key.
- An `EXTERNAL ACCESS INTEGRATION` binding the network rule and secret.
- A minimal Python stored procedure, `NULLAFI_PHASE2_CONNECTIVITY_TEST`, that
  calls Nullafi's `/scan` endpoint with one synthetic value.
- Static tests that verify the setup SQL keeps only a placeholder API key in the
  repository.
- A successful live smoke test using only a synthetic SSN-like value.

### Run In Snowflake

Open `snowflake/phase2_connectivity.sql` in a private Snowflake worksheet,
choose your role/warehouse/database/schema, replace the API-key placeholder in
the worksheet only, and run the script.

The smoke test is:

```sql
CALL NULLAFI_PHASE2_CONNECTIVITY_TEST();
```

Example success shape (any HTTP 2xx `status_code` is successful):

```json
{
  "ok": true,
  "status_code": 200,
  "changed": true
}
```

`changed: true` confirms that the configured policy returned an obfuscated
value. A 2xx response remains the connectivity proof; `changed` is the policy
application signal for this synthetic SSN test.

See `SETUP.md` for privilege notes, troubleshooting, and the query-history check
for secret exposure.

### Remaining Phase 2 Closeout

- Rotate the Nullafi API key used during live setup, replace the Snowflake
  Secret with the new key, and run the query-history check in `SETUP.md`.
- Optionally rerun the local Phase 1 POC in strict mode now that the Nullafi
  SSN obfuscation policy is active.

## Phase 1: Local POC

Phase 1 proves the Nullafi API behavior locally before any Snowflake code is
introduced. The POC reads synthetic records, sends non-null fields to Nullafi's
scan endpoint, normalizes the response, and asserts that fields listed in
`expected_sensitive_fields` are changed by the configured Nullafi rules.

### What Phase 1 Added

- Synthetic test data in `data/fake_sensitive_data.json`.
- A small Nullafi HTTP client in `src/nullafi_client.py`.
- A runnable local proof-of-concept script in `src/phase1_poc.py`.
- Unit tests for local parsing, payload preparation, request construction, and
  controlled API error handling.
- A committed `.env.example` with dummy values only.
- Local documentation for setup, test commands, and live API verification.

### Setup

Create and activate a virtual environment, then install dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Create a local `.env` file from the committed example:

```bash
cp .env.example .env
```

Fill in these required values:

```text
NULLAFI_API_KEY=nul_your_real_key_here
NULLAFI_NAMESPACE=dlp test
NULLAFI_BASE_URL=https://openflow.nullafi.net/api
```

Keep `NULLAFI_SCAN_PATH=/scan` unless your base URL already requires a different
path. Do not commit `.env`; it is ignored by git.

### Run

```bash
python src/phase1_poc.py
```

The script writes normalized output to `phase1_results.json`. That file is local
debug output and is ignored by git.

If you are still tuning the Nullafi dashboard rule and want the script to finish
while reporting unchanged planted fields as warnings, run:

```bash
python src/phase1_poc.py --allow-unchanged-expected
```

You can also verify the API manually with curl:

```bash
set -a
source .env
set +a

curl -X POST \
  "https://openflow.nullafi.net/api/scan?namespace=dlp%20test" \
  -H "Authorization: Bearer ${NULLAFI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"ssn":"123-45-6789"}'
```

### Test

```bash
python -m pytest
```

The unit tests do not call Nullafi. They cover local parsing, null handling,
request construction, and controlled API error handling.

### Phase 1 Validation

- Local unit tests pass with `python -m pytest`.
- The live curl request reaches Nullafi successfully using:
  - `NULLAFI_BASE_URL=https://openflow.nullafi.net/api`
  - `NULLAFI_SCAN_PATH=/scan`
  - `NULLAFI_NAMESPACE=dlp test`
- The Nullafi dashboard shows the request and detects the SSN activity.
- The dashboard policy now applies an SSN obfuscation rule to `dlp test`; the
  Snowflake Phase 2 smoke test returned `changed: true` for the synthetic SSN.

### Left For Later

- Rerun `python src/phase1_poc.py` without `--allow-unchanged-expected` to
  validate the local strict assertion path against the active policy.
- Confirm and document the final obfuscated response shape if it differs from
  the current normalized field-level representation.
- Run broader rate-limit and max-payload tests after obfuscation is working.
- Phase 2 starts Snowflake connectivity: Network Rule, Secret, External Access
  Integration, and a minimal stored procedure that calls Nullafi.
