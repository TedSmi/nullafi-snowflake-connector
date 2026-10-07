# Nullafi Snowflake Connector

A Snowflake-native connector that sends selected fields through Nullafi before
downstream use. It is installed with one SQL script and provides an
insert-triggered pipeline, durable work queue, idempotent result table, error
log, run log, and task-failure monitoring.

**Status:** the installer has passed clean-environment validation and the local
test suite. It is ready for controlled evaluation. Complete the
[production-readiness checklist](#production-readiness-checklist) before using
it with production data.

## How it works

```text
source-table INSERT
        |
Snowflake stream -> durable ID-only queue -> Nullafi /scan
        |                                      |
        +------------------------------------> configured output table
                                                   |
                                    run log, error log, task-failure log
```

The processor consumes only plain `INSERT` stream events. It writes one output
row per configured source field and merges by configuration, source record ID,
and source column, so a normal retry does not create duplicate output rows.
The source table is never changed.

The supported installer is [`snowflake/install_connector.sql`](snowflake/install_connector.sql).
The earlier SQL files are retained as isolated examples and diagnostics; do not
run them in the connector schema.

## Before you install

You need:

- A Snowflake account with external network access and Python stored procedure
  packages `requests` and `snowflake-snowpark-python` available.
- A role with the privileges to create the connector objects: network rule,
  secret, procedure, table, stream, task, and (at account level) external
  access integration. The task owner also needs `USAGE` on its warehouse.
- `SELECT` access to the source table and permission to create/write the output
  table in the chosen output schema.
- A Nullafi API key that can scan in the configured namespace, and an active
  Nullafi policy that produces the protection behavior you expect.
- A source table with a stable, non-null, unique key. Every selected scan column
  must exist. Use simple, unquoted Snowflake identifiers only; quoted or
  mixed-case identifiers are intentionally unsupported.

Plan the data boundary before installation. Nullafi receives non-null configured
field values. The output table contains returned (potentially obfuscated)
values. Error and raw-response storage can be sensitive; see
[Data handling](#data-handling).

## Install

1. Create or select a dedicated connector schema. The installer uses
   `CREATE OR REPLACE` for connector-owned objects named `NULLAFI_CONNECTOR_*`.
   Do not run it in a schema containing unrelated objects with those names.
2. Open [`snowflake/install_connector.sql`](snowflake/install_connector.sql) in
   a private Snowflake worksheet. Set the four `USE ...` context statements,
   then set every value in the parameter block: source table, source key, scan
   columns, output table, Nullafi namespace, task warehouse, and schedule.
3. Review the optional batch and raw-response settings in that same parameter
   block. Replace `<PASTE_NULLAFI_API_KEY_HERE>` only in the private worksheet. Do
   not save the key in source control, a shared worksheet, or application logs.
4. Run the complete script. It creates the objects, validates the table/column
   mapping, and leaves both tasks suspended.
5. Review the configuration and make one controlled processing call:

   ```sql
   SELECT * FROM NULLAFI_CONNECTOR_CONFIG;
   CALL NULLAFI_CONNECTOR_VALIDATE_CONFIG();
   CALL NULLAFI_CONNECTOR_PROCESS();

   SELECT *
   FROM NULLAFI_CONNECTOR_RUN_LOG
   ORDER BY STARTED_AT DESC;
   ```

6. Review results and errors before enabling automation:

   ```sql
   SELECT *
   FROM <configured output table>
   ORDER BY SCANNED_AT DESC;

   SELECT *
   FROM NULLAFI_CONNECTOR_ERROR_LOG
   ORDER BY OCCURRED_AT DESC;
   ```

7. When the controlled run is correct, enable both tasks:

   ```sql
   ALTER TASK NULLAFI_CONNECTOR_PROCESS_TASK RESUME;
   ALTER TASK NULLAFI_CONNECTOR_MONITOR_TASK RESUME;
   ```

## Configuration reference

Set these values in the parameter block before running the installer.

| Setting | Meaning | Production guidance |
| --- | --- | --- |
| `NULLAFI_SOURCE_TABLE` | One- to three-part source-table identifier. | Use a table with a stable, unique record key. |
| `NULLAFI_SOURCE_KEY_COLUMN` | Source column that identifies a record. | It must be non-null and unique. |
| `NULLAFI_SCAN_COLUMNS` | JSON array of source fields to send to Nullafi. | Include only fields approved for external scanning; exclude the source key. |
| `NULLAFI_OUTPUT_TABLE` | Destination for per-field scan results. | Choose a protected schema and set retention/access controls. |
| `NULLAFI_NAMESPACE` | Nullafi application namespace sent with `/scan`. | Verify it maps to the intended production rules. |
| `NULLAFI_TASK_WAREHOUSE` | Warehouse used by both tasks. | Size it from representative load testing. |
| `NULLAFI_TASK_SCHEDULE` | Snowflake task schedule. | Choose a cadence that matches latency and cost requirements. |
| `NULLAFI_MAX_FIELD_CHARACTERS` | Maximum field length sent to Nullafi. | Replace the `1000` default only after endpoint-limit testing. |
| `NULLAFI_MAX_VALUES_PER_REQUEST` | Maximum fields in one `/scan` request. | Replace the `20` default only after endpoint-limit testing. |
| `NULLAFI_STORE_RAW_RESPONSES` | Whether API responses are retained. | Keep `FALSE` unless short-lived diagnostics are approved. |

The validator rejects malformed identifiers, duplicate scan columns, a key also
listed as a scan column, missing source/output columns, empty namespace,
unsupported update policy, null keys, and duplicate source keys.

## Operation and monitoring

### Expected behavior

- An inserted row is queued and scanned once.
- An update is not rescanned (`INSERT_ONLY` is the only supported policy).
- If a queued source row is deleted before processing, it is marked
  `SKIPPED_SOURCE_DELETED` and is not sent to Nullafi.
- Null inputs produce `SKIPPED_NULL` output rows without an API call.
- A field exceeding `MAX_FIELD_CHARACTERS` is logged as a recoverable error and
  is not sent.
- API or response failures mark participating queue rows as `FAILED`; unaffected
  batches continue.

Inspect health regularly:

```sql
SELECT *
FROM NULLAFI_CONNECTOR_PIPELINE_ALERTS
ORDER BY STARTED_AT DESC;

SELECT *
FROM NULLAFI_CONNECTOR_TASK_FAILURE_LOG
ORDER BY RECORDED_AT DESC;

SELECT QUEUE_STATUS, COUNT(*)
FROM NULLAFI_CONNECTOR_WORK_QUEUE
GROUP BY QUEUE_STATUS;
```

Run a bounded retry for failed work only after resolving its cause:

```sql
CALL NULLAFI_CONNECTOR_PROCESS('DEFAULT', 100, TRUE);
```

Suspend processing before maintenance or incident response:

```sql
ALTER TASK NULLAFI_CONNECTOR_PROCESS_TASK SUSPEND;
ALTER TASK NULLAFI_CONNECTOR_MONITOR_TASK SUSPEND;
```

The tasks suspend automatically after three consecutive task-level failures.
Recoverable row/API errors do not fail a task; monitor the pipeline-alert view
as well as task history.

## Data handling

The connector intentionally keeps its queue ID-only. It does not copy source
plaintext into the queue. The output table stores the value returned by
Nullafi; that value can be sensitive and may be unchanged when no configured
policy modifies it. The error table does not store request values or headers;
response bodies are stored only when
`STORE_RAW_RESPONSES` is enabled. Apply your organization’s data classification,
retention, RBAC, audit, and deletion rules to all connector-owned tables.

The connector uses a Snowflake `GENERIC_STRING` secret bound to the processor
at procedure-creation time. The secret value is not returned or logged by the
implementation. Use a private worksheet or approved secret-injection workflow,
then perform the query-history exposure check in [`SETUP.md`](SETUP.md).

## Local verification

The local Python client and synthetic data are optional tools for API-contract
testing; they do not install the connector. To run the repository test suite:

```bash
python3 -m venv venv
venv/bin/pip install -r requirements.txt
venv/bin/python -m pytest -q
```

`SETUP.md` documents the standalone Snowflake connectivity diagnostic and its
secret-exposure check. Use it only in an isolated schema when diagnosing network
access or Nullafi authentication.

## Known limitations

- Only simple, unquoted one-, two-, or three-part identifiers are supported.
- Processing is insert-only; updates do not trigger rescanning.
- Automatic exponential retry/backoff, rate-limit coordination, and external
  notification delivery are not implemented.
- Entity types are not written because the confirmed `/scan` response contract
  does not provide them.
- The installer is designed for one `DEFAULT` configuration per connector
  schema and creates/replaces connector-owned objects on rerun.

## Production readiness checklist

Do not treat a successful installation as production approval. Complete and
record these items for the intended account and dataset.

- [ ] Create a dedicated least-privilege production role; review grants for the
  source, output, connector schema, warehouse, secret, and external access
  integration.
- [ ] Create a new least-privilege Nullafi API key, rotate the validation key,
  and place the new key only in the Snowflake Secret through a private or
  approved secret-management workflow.
- [ ] Search Snowflake query history for a safe short fragment of the key as
  documented in `SETUP.md`; if it appears, revoke/rotate the key and document
  the exposure response.
- [ ] Confirm `STORE_RAW_RESPONSES = FALSE`, restrict reader access to output
  and error tables, and approve retention/deletion/backup requirements for
  every connector-owned table.
- [ ] Validate the production Nullafi namespace, policy, rule coverage, and
  expected obfuscation results using synthetic test values.
- [ ] Measure the maximum field characters, total request payload, and number
  of values/arguments supported by Nullafi `/scan`. Test boundaries, malformed
  responses, timeouts, 4xx/5xx, rate limits, and partial failures; then set
  `MAX_FIELD_CHARACTERS` and `MAX_VALUES_PER_REQUEST` with safety headroom.
- [ ] Verify the actual source key is immutable, non-null, and unique; verify
  all scan columns and the insert-only update/delete behavior meet requirements.
- [ ] Load test representative volumes and field sizes. Set warehouse size,
  schedule, `MAX_ROWS`, concurrency expectations, and cost alerts from results.
- [ ] Test recovery from an API outage, failed batch, task auto-suspension,
  manual retry, queued-source deletion, secret rotation, and task resumption.
- [ ] Connect pipeline and task-failure tables to an owned monitoring/alerting
  service with severity, escalation, and response-time expectations.
- [ ] Write and exercise a runbook for daily health checks, incident response,
  policy/schema changes, secret rotation, rollback, and business continuity.
- [ ] Re-run the automated tests and a clean-environment installation for the
  release candidate; retain the validation evidence and publish versioned
  release notes with compatibility and rollback guidance.
- [ ] Obtain security, privacy, data-governance, and service-owner approval for
  sending the selected fields to Nullafi.
- [ ] Convert to a Snowflake Native App.
