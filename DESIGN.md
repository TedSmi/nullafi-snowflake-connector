# Design Notes

## Nullafi API findings (Phase 0.1)
- Auth method: Bearer token in the `Authorization` header (`Authorization: Bearer <token>`).
  Token comes from a Dashboard-generated API Key (Settings -> API Keys). Keys must have
  a "Data Scanning" (or equivalent) right explicitly granted — a key scoped only for
  "Policy Definition" returns 403 Forbidden on /scan even with a correct namespace and
  active rule.
- Endpoint chosen: `POST /scan` (not `/scan-dynamic`) — detection/obfuscation rules are
  configured server-side in the Nullafi dashboard (Applications + Rules), not passed
  per-request.
  - Query params: `namespace` (required, matches an Application's API-scanning
    filter; the configured test value is `dlp test`),
    `username` (optional, activity tracking), `usergroup` (optional, activity tracking).
  - Request body: JSON object with the content to scan, e.g. `{"ssn": "122-12-8348"}`.
    CONFIRMED WORKING — returns HTTP 200.
- Response format (confirmed): JSON object, same top-level key(s) as the request.
  An initial API call detected the SSN but returned it unchanged because the event
  showed `Rule: (None)`. After adding the matching API-scanning application filter,
  enabled obfuscation rule, and SSN obfuscation configuration, the Phase 2 test
  returned `changed: true` for `122-12-8348`.
- Error response format (confirmed): `{"code": <int>, "message": "<string>"}` — seen on
  401 and 403.
- Rate limits: unknown — not in Swagger docs. Deferred until dedicated measurements
  can be run against the now-working policy path.
- Max payload size: unknown — deferred until dedicated measurements can be run against
  the now-working policy path.
- Batch support: local POC sends multiple top-level keys in one JSON object. Full live
  validation of multi-key obfuscation is deferred until an active rule is attached.
- Reversibility ("store original value"): not a param on `/scan` (that's `/scan-dynamic`
  only). For `/scan`, this is set on the Rule/Obfuscation config in the dashboard.
  The connector uses one-way obfuscation.

## Input table schema
- Columns to be scanned: TBD count/names — N configurable string columns, driven by the
  config approach below.
- Column types: string/varchar, since Nullafi's endpoint takes JSON text content.

## Output table schema
- Reference to source row (source table's primary key)
- Scanned column name
- Obfuscated/masked value (field name TBD until a confirmed real obfuscation is observed)
- Detected data type(s) (field name TBD, same caveat)
- Scan timestamp
- Scan status (SUCCESS / ERROR / NO_MATCH — may need a distinct status for "API call
  succeeded but nothing matched the configured rules")
- Raw API response (JSON) — keep temporarily for debugging while schema is unconfirmed

## Edge case handling
- Null values: skip the API call entirely, pass through as null in the output.
- Non-string columns: cast to string before sending.
- Oversized fields: limit unknown — assume conservative chunking (e.g. 1000 chars) until
  future live testing reveals the real limit.

## Configuration approach (Phase 0.5)
Decision: a config table in Snowflake holding, at minimum:
- `namespace` — the Nullafi Application namespace
- source table + column list to scan
- output table name
- reference to a Snowflake Secret holding the API key (the key itself never lives in
  this table)

## Open items carried into Phase 1
- Obfuscation confirmation is complete: the matching API-scanning application
  filter plus active SSN rule changed the synthetic SSN in the Phase 2 smoke
  test (`changed: true`).
- The normalized response tracks the returned field value and `changed` state.
  Dedicated entity-type metadata is still not exposed by the confirmed response
  shape and remains unavailable to Phase 3.
- Determine what "Data Scanning" right is called exactly in the key generation flow, so
  SETUP.md (Phase 2) can document it precisely for a new user.

## Phase 1 local POC notes
- Phase 1 repository work is complete and ready to commit. Policy-driven SSN
  obfuscation was later confirmed through the Phase 2/3 Snowflake validation.
- Local test data lives in `data/fake_sensitive_data.json`.
  - Each row contains `scan_fields`, `expected_sensitive_fields`, and `field_notes`.
  - `field_notes` documents why each fake field exists, since JSON does not support
    comments.
  - `expected_sensitive_fields` starts with `ssn` because that is the immediate
    Phase 0 open question. Add email, credit-card, or name fields to that list
    after those Nullafi dashboard rules are intentionally enabled.
- Local client code lives in `src/nullafi_client.py`.
  - Required env vars: `NULLAFI_API_KEY`, `NULLAFI_NAMESPACE`, `NULLAFI_BASE_URL`.
  - Optional env vars: `NULLAFI_SCAN_PATH`, `NULLAFI_USERNAME`,
    `NULLAFI_USERGROUP`, `NULLAFI_TIMEOUT_SECONDS`.
  - Default endpoint path is `/scan`, matching the Phase 0 confirmed endpoint.
- Local runner lives in `src/phase1_poc.py`.
  - Null values are skipped before calling Nullafi.
  - Non-null values are cast to strings before scanning.
  - Raw API responses are preserved in `phase1_results.json` for debugging while
    the stable response schema is still being confirmed.
  - `--allow-unchanged-expected` lets the live script complete while dashboard
    rules are being tuned, but the strict default is to fail if expected sensitive
    fields are unchanged.
- Manual curl testing confirmed the correct URL shape:
  - `NULLAFI_BASE_URL=https://openflow.nullafi.net/api`
  - `NULLAFI_SCAN_PATH=/scan`
  - Full endpoint: `https://openflow.nullafi.net/api/scan?namespace=dlp%20test`
- Live dashboard observations:
  - Nullafi activity is recorded for app/origin `dlp test`.
  - SSN detection appears in dashboard activity.
  - The initial event showed `Rule: (None)` and returned an unchanged value.
  - Adding an API-scanning application filter for `dlp test`, attaching an
    enabled SSN obfuscation rule, and rerunning the Phase 2 test returned
    `changed: true`.
- Current normalized response shape:
  - `record_id`
  - `field_results[]`
    - `field_name`
    - `original_value`
    - `returned_value`
    - `changed`
    - `expected_sensitive`
  - `skipped_null_fields[]`
  - `raw_response`
- Phase 1 accomplishments:
  - Created synthetic data with positive and negative/control-like fields.
  - Added a reusable local Nullafi client with bearer auth, timeout handling,
    JSON response validation, and clear 401/403/429/5xx errors.
  - Added a local runner with structured logging and assertions.
  - Added unit tests that do not call the live API.
  - Confirmed the live API endpoint/auth/namespace path with curl.
  - Identified and resolved application/rule setup as the obfuscation blocker.
- Deferred/skipped for now:
  - Detailed entity-type metadata and any response fields beyond the confirmed
    returned value/change state.
  - Practical rate-limit testing, now that it can be measured against the active
    rule path.
  - Practical max-payload testing, for the same reason.
  - Snowflake connectivity, which starts in Phase 2.

## Phase 2 Snowflake connectivity design
- Snowflake object pattern:
  - `NULLAFI_API_NETWORK_RULE`: schema-level egress rule using
    `MODE = EGRESS`, `TYPE = HOST_PORT`, and `VALUE_LIST = ('openflow.nullafi.net')`.
  - `NULLAFI_API_KEY`: schema-level `GENERIC_STRING` secret containing the bearer
    token. The repository keeps only a placeholder value.
  - `NULLAFI_EXTERNAL_ACCESS_INTEGRATION`: account-level integration that allows
    only the Nullafi network rule and the Nullafi secret.
  - `NULLAFI_PHASE2_CONNECTIVITY_TEST`: minimal Python stored procedure that uses
    `EXTERNAL_ACCESS_INTEGRATIONS` plus a `SECRETS` alias to call `/scan`.
- Stored procedure vs. UDF:
  - Decision: use a stored procedure.
  - Reason: later phases need operational side effects: reading batches, writing
    output/error/run-log tables, and controlling retry behavior. A UDF is more
    natural for pure row-level transformations, but this connector is a pipeline
    component.
- Public egress vs. private connectivity:
  - Decision: Phase 2 uses public internet egress to `openflow.nullafi.net`.
  - Tradeoff: public egress is simpler and adequate for the first connectivity
    proof. Private connectivity may be preferable for production accounts with
    stricter network posture, but it introduces cloud/provider-specific setup and
    Snowflake edition constraints.
- Inline procedure vs. staged Python file:
  - Decision: keep the Phase 2 handler inline in SQL.
  - Tradeoff: inline SQL is easier for a new user to run in a worksheet and avoids
    stage packaging during the connectivity proof. Phase 3+ can move pipeline
    logic into staged Python modules if the procedure grows enough to make inline
    code hard to review.
- Diagnostic return shape:
  - The procedure returns a Snowflake `VARIANT` with `ok`, `status_code`,
    request metadata, response body, and a `changed` boolean.
  - It does not return request headers or the secret value.
  - A successful 2xx response with `changed = false` still proves connectivity; it carries
    forward the Phase 1 rule-attachment blocker.
- Secret exposure handling:
  - The source SQL intentionally contains only `<PASTE_NULLAFI_API_KEY_HERE>`.
  - `SETUP.md` instructs the user to paste the key only in a private Snowflake
    worksheet and to run a query-history search using a short key fragment.
  - If query history exposes the real key, rotate the key and update the
    Snowflake Secret immediately.
- Phase 2 validation status:
  - Repository artifacts and static tests are complete.
  - Live validation succeeded in the upgraded Snowflake account. Calling
    `NULLAFI_PHASE2_CONNECTIVITY_TEST()` returned `ok: true`, HTTP `200`, and
    `{"phase2_test_value": "122-12-8348"}`.
  - After configuring the matching API-scanning filter and active SSN rule,
    calling the procedure with `dlp test` returned `changed: true`. This confirms
    connectivity, authentication, and policy-driven obfuscation.
  - Before Phase 2 is closed, rotate the live API key used during setup, replace
    the Snowflake Secret, and complete the query-history exposure check.

## Phase 3 batch-pipeline design

### Sample object model
- `NULLAFI_PHASE3_SAMPLE_INPUT` is a synthetic, five-column source table.
  `RECORD_ID` identifies a source row; `PROCESSING_STATUS` is `PENDING`,
  `PROCESSED`, or `FAILED`. `LAST_PROCESSED_AT` and `LAST_ERROR_MESSAGE` make
  its operational state inspectable.
- `NULLAFI_PHASE3_SCAN_OUTPUT` holds one result for each
  `(SOURCE_RECORD_ID, SCAN_COLUMN)`. It stores the returned/obfuscated value,
  whether the returned value changed, a scan status, a timestamp, and the run
  identifier. It does not duplicate the original field value: the source table
  remains the authoritative location for plaintext. `RAW_API_RESPONSE` is
  temporary debugging data and can itself include plaintext, so production
  retention/access policy must be decided before it is enabled broadly.
- `NULLAFI_PHASE3_ERROR_LOG` is the dead-letter table. It records error stage,
  HTTP status, and service response but never request headers, API keys, or
  request payload values.
- `NULLAFI_PHASE3_RUN_LOG` contains per-invocation metrics: selected,
  processed, failed, output-written, API-call, and API-failure counts.
  `STARTED_AT`, `FINISHED_AT`, and `DURATION_MS` provide the basic duration
  metric without relying on client-side clock time.

### Batching and response mapping
- The confirmed `/scan` shape is a JSON object with multiple top-level keys.
  Phase 3 batches up to 20 field values per request. It gives each value an
  opaque payload key (`v_1`, `v_2`, and so on), then maps the same returned key
  back to its source record and source column. This avoids collisions when two
  records both have an `SSN` field.
- The procedure keeps all scannable fields from a source record in the same
  HTTP batch. A batch failure can therefore mark only its participating source
  records failed while later batches continue.
- Actual Nullafi rate and max-payload limits are still unmeasured. Until dedicated
  measurements are performed against the now-working obfuscation policy, the
  implementation uses a conservative 20 values/request and rejects (rather
  than silently truncating) fields over 1,000 characters.
- The API response currently does not expose confirmed entity-type metadata.
  `DETECTED_ENTITY_TYPES` is reserved and remains `NULL`. A changed returned
  value gets `SUCCESS`; an unchanged successful value gets `NO_MATCH`. The
  latter indicates no configured policy changed that value; it is not by itself
  proof that no sensitive data exists.

### Failure handling and reruns
- An HTTP exception, non-2xx response, invalid JSON object, or missing returned
  payload key produces error-log entries and marks only affected source rows
  `FAILED`. It does not abort unrelated batches.
- Output uses `MERGE` on `(SOURCE_RECORD_ID, SCAN_COLUMN)`, so retrying a row
  updates prior per-field results instead of adding duplicates.
- The default procedure reads `PENDING` rows only. This makes the ordinary
  second run a no-op for successfully processed records. `RETRY_FAILED = TRUE`
  explicitly opts into retrying failed rows.
- A database/configuration failure outside the recoverable HTTP path closes the
  run log as `FAILED` and is re-raised to the caller; this makes deployment
  mistakes visible rather than silently treating them as data failures.

### Scope boundary
- Phase 3 uses fixed sample names and columns so it can be run and reviewed as
  an isolated POC. It is not yet a drop-in production installer: phase 6 will
  source table/column/namespace configuration from the planned Snowflake config
  table and validate that configuration before execution.
