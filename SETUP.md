# Phase 2 Snowflake Setup

This setup proves Snowflake can call Nullafi from a Python stored procedure using
Snowflake-managed external network access and a Snowflake Secret.

## Prerequisites

- A Snowflake role that can create network rules in the target schema.
- A Snowflake role that can create external access integrations at the account
  level, commonly `ACCOUNTADMIN`.
- A Snowflake role that can create secrets and Python stored procedures in the
  target schema.
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

A successful result has `"ok": true` and `"status_code": 200`. If `"changed"` is
`false`, that can still match the Phase 1 finding: Nullafi accepted and scanned
the request, but no dashboard rule is attached to obfuscate the value yet.

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
