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
  - Query params: `namespace` (required, matches a dashboard Application, e.g. "dlp test"),
    `username` (optional, activity tracking), `usergroup` (optional, activity tracking).
  - Request body: JSON object with the content to scan, e.g. `{"ssn": "122-12-8348"}`.
    CONFIRMED WORKING — returns HTTP 200.
- Response format (confirmed): JSON object, same top-level key(s) as the request.
  Phase 1 live curl confirmed that values may come back unchanged even when Nullafi
  detects the SSN in dashboard activity. In the observed dashboard event, the app/origin
  was `dlp test`, but `Rule` displayed `(None)`. Current interpretation: the API
  request is valid and detection is happening, but no dashboard rule is attached to
  obfuscate the value for this app/namespace yet.
- Error response format (confirmed): `{"code": <int>, "message": "<string>"}` — seen on
  401 and 403.
- Rate limits: unknown — not in Swagger docs. Deferred until the dashboard obfuscation
  rule is attached, so test results reflect the real production-like path.
- Max payload size: unknown — deferred until the dashboard obfuscation rule is attached.
- Batch support: local POC sends multiple top-level keys in one JSON object. Full live
  validation of multi-key obfuscation is deferred until an active rule is attached.
- Reversibility ("store original value"): not a param on `/scan` (that's `/scan-dynamic`
  only). For `/scan`, this must be set on the Rule/Obfuscation config in the dashboard —
  confirm exact location before Phase 3. We want one-way (non-reversible) obfuscation.

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
- Confirm obfuscation actually triggers with a value known to match the rule's regex.
  Phase 1 narrowed this down: the dashboard detects the SSN, but currently shows
  `Rule: (None)`, so obfuscation cannot be confirmed until a rule is attached.
- Confirm the field name(s) used for matched/obfuscated content in the response.
  Still open until an active rule changes the response.
- Determine what "Data Scanning" right is called exactly in the key generation flow, so
  SETUP.md (Phase 2) can document it precisely for a new user.

## Phase 1 local POC notes
- Phase 1 repository work is complete and ready to commit. The remaining obfuscation
  confirmation depends on external Nullafi dashboard rule setup, not on local code.
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
- Live dashboard observation:
  - Nullafi activity is recorded for app/origin `dlp test`.
  - SSN detection appears in dashboard activity.
  - `Rule` currently shows `(None)`.
  - Because no rule is applied, the `/scan` response currently returns SSNs
    unchanged.
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
  - Identified dashboard rule setup as the blocker for obfuscation.
- Deferred/skipped for now:
  - Exact obfuscated response shape, because no active rule is currently applied.
  - Practical rate-limit testing, because it should be measured after the rule path
    is configured.
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
  - A successful 200 with `changed = false` still proves connectivity; it carries
    forward the Phase 1 rule-attachment blocker.
- Secret exposure handling:
  - The source SQL intentionally contains only `<PASTE_NULLAFI_API_KEY_HERE>`.
  - `SETUP.md` instructs the user to paste the key only in a private Snowflake
    worksheet and to run a query-history search using a short key fragment.
  - If query history exposes the real key, rotate the key and update the
    Snowflake Secret immediately.
- Phase 2 validation status:
  - Repository artifacts and static tests are complete.
  - Live validation remains account-dependent: run
    `CALL NULLAFI_PHASE2_CONNECTIVITY_TEST();` in Snowflake and record the result.
  - Trial-account blocker observed: Snowflake returned
    `External access is not supported for trial accounts` when creating the
    external access path. This blocks a true Snowflake -> Nullafi live proof on
    that account, but does not change the connector design.
