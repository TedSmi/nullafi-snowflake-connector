# Phase 2 Snowflake Setup

This setup proves Snowflake can call Nullafi from a Python stored procedure using
Snowflake-managed external network access and a Snowflake Secret.

## Prerequisites

- A Snowflake account with external network access enabled. It is disabled by
  default for trial accounts; ask Snowflake to enable it or use a paid account.
- A Snowflake role with `USAGE` on the target database and schema, plus
  `CREATE NETWORK RULE`, `CREATE SECRET`, and `CREATE PROCEDURE` on the target
  schema.
- To create the external access integration: the account-level `CREATE
  INTEGRATION` privilege, plus `USAGE` on `NULLAFI_API_KEY` and on the schema
  that contains it. `ACCOUNTADMIN` normally has these privileges.
- To create the procedure: `READ` on `NULLAFI_API_KEY`, `USAGE` on the schema
  that contains it, and `USAGE` on `NULLAFI_EXTERNAL_ACCESS_INTEGRATION`.
  These grants matter when the setup is split between an account administrator
  and a developer role.
- A warehouse available to compile and run the stored procedure.
- Snowflake Python package support enabled for `requests` and
  `snowflake-snowpark-python`.
- A Nullafi API key with the data-scanning permission enabled.
- The Nullafi namespace/application you used in Phase 1, for example `dlp test`.

## Objects Created

`snowflake/phase2_connectivity.sql` creates:

- `NULLAFI_API_NETWORK_RULE`
- `NULLAFI_API_KEY`
- `NULLAFI_EXTERNAL_ACCESS_INTEGRATION`
- `NULLAFI_PHASE2_CONNECTIVITY_TEST`

## Run The Setup

Open `snowflake/phase2_connectivity.sql` in a private Snowflake worksheet, then:

1. Set the role, warehouse, database, and schema at the top of the worksheet.
2. Replace `<PASTE_NULLAFI_API_KEY_HERE>` with the real Nullafi API key only in
   the worksheet.
3. Run the script.
4. Do not save or commit the worksheet text with the real key.

The final statement calls:

```sql
CALL NULLAFI_PHASE2_CONNECTIVITY_TEST();
```

A successful result has `"ok": true` and a `"status_code"` in the HTTP 2xx range
(for example, `200`). With an active matching obfuscation policy, the synthetic
SSN test should also return `"changed": true`. A `false` value still proves
connectivity, but indicates that the matching policy did not change the value.

If your Nullafi namespace or endpoint differs from the defaults, call the
procedure with explicit arguments:

```sql
CALL NULLAFI_PHASE2_CONNECTIVITY_TEST(
  'your namespace',
  '122-12-8348',
  'https://openflow.nullafi.net/api',
  '/scan'
);
```

Use only synthetic test values for Phase 2. The procedure returns the API
response body so you can inspect connectivity behavior.

## Verify Secret Handling

The procedure reads the API key through Snowflake's secret API:

```python
_snowflake.get_generic_secret_string("nullafi_api_key")
```

It never returns the key, logs the key, or includes request headers in the
diagnostic output.

After setup, run the query-history check at the bottom of
`snowflake/phase2_connectivity.sql` with a short key fragment. If any result
shows the real key in query text, rotate the Nullafi key and update the
Snowflake Secret immediately.

## Common Failures

- `403`: the key or namespace is not authorized for Nullafi scanning.
- `401`: the key is missing, expired, or wrong.
- External network access error: confirm `NULLAFI_API_NETWORK_RULE` allows the
  exact host in `NULLAFI_BASE_URL`.
- Secret authorization error: confirm `NULLAFI_API_KEY` is listed in
  `ALLOWED_AUTHENTICATION_SECRETS` and is also named in the procedure's
  `SECRETS` clause.

## Phase 3 Sample Pipeline

After the Phase 2 objects are present, run the complete
`snowflake/phase3_batch_pipeline.sql` file in the same schema. It creates a
synthetic input table, result table, dead-letter table, run-log table, and
`NULLAFI_PROCESS_BATCH`.

The script ends with a first procedure call plus inspection queries. A healthy
run has all input rows in `PROCESSED`; it creates 15 output rows (three sample
records times five scanned fields), including one `SKIPPED_NULL` result. With
the configured SSN obfuscation policy, `cust_001` and `cust_002` should show
`SUCCESS` and `VALUE_CHANGED = TRUE` for their SSN output rows. Control values
that do not match a configured policy can still show `NO_MATCH`.

Run these checks after the initial call:

```sql
SELECT PROCESSING_STATUS, COUNT(*) AS ROW_COUNT
FROM NULLAFI_PHASE3_SAMPLE_INPUT
GROUP BY PROCESSING_STATUS;

SELECT SOURCE_RECORD_ID, SCAN_COLUMN, SCAN_STATUS, VALUE_CHANGED
FROM NULLAFI_PHASE3_SCAN_OUTPUT
ORDER BY SOURCE_RECORD_ID, SCAN_COLUMN;

SELECT *
FROM NULLAFI_PHASE3_ERROR_LOG
ORDER BY OCCURRED_AT DESC;

SELECT *
FROM NULLAFI_PHASE3_RUN_LOG
ORDER BY STARTED_AT DESC;
```

For rerun safety, call the procedure again with no arguments. It processes only
`PENDING` rows, so the second run should select zero rows and output row count
should remain 15. To retry only dead-lettered rows, opt in explicitly:

```sql
CALL NULLAFI_PROCESS_BATCH(100, TRUE);
```

The procedure currently caps individual values at 1,000 characters and batches
at most 20 values in one Nullafi request. Those are conservative temporary
limits, not documented Nullafi limits. An oversized value or failed request is
recorded in `NULLAFI_PHASE3_ERROR_LOG`; the procedure continues processing
unrelated batches.

Use only the included synthetic data for this Phase 3 validation. The raw API
response is retained in the output table for temporary debugging and may
contain sensitive plaintext when real data is introduced; restrict access and
define a retention policy before using this design beyond the POC.

## Design Decisions And Tradeoffs

- Stored procedure instead of UDF: this connector will eventually perform I/O,
  write status tables, and handle errors. A procedure is the better fit for that
  pipeline shape.
- SQL-first setup: Phase 2 validates Snowflake account objects, so a worksheet
  script is more direct than adding a local deployment client.
- One fixed network host: the rule allows only `openflow.nullafi.net`, keeping
  egress tight. If Nullafi gives you a different tenant host, change the host in
  the network rule and keep the allowlist narrow.
- Diagnostic return body: the procedure returns enough response detail to debug
  setup, but it does not return the secret or request headers.
