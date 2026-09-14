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
  OPEN QUESTION: our test value came back completely unchanged (no obfuscation applied).
  Need to confirm whether this means (a) the value didn't match the configured rule's
  regex, or (b) something in the rule/obfuscation config needs adjusting. Re-test with a
  value confirmed to match the DataType's regex before Phase 1.
- Error response format (confirmed): `{"code": <int>, "message": "<string>"}` — seen on
  401 and 403.
- Rate limits: unknown — not in Swagger docs. Test empirically in Phase 1.
- Max payload size: unknown — test empirically in Phase 1.
- Batch support: unclear — no dedicated batch endpoint found. Worth testing whether the
  request body accepts multiple keys in one call (e.g. `{"ssn": "...", "email": "..."}`).
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
  Phase 1 testing reveals the real limit.

## Configuration approach (Phase 0.5)
Decision: a config table in Snowflake holding, at minimum:
- `namespace` — the Nullafi Application namespace
- source table + column list to scan
- output table name
- reference to a Snowflake Secret holding the API key (the key itself never lives in
  this table)

## Open items carried into Phase 1
- Confirm obfuscation actually triggers with a value known to match the rule's regex.
- Confirm the field name(s) used for matched/obfuscated content in the response.
- Determine what "Data Scanning" right is called exactly in the key generation flow, so
  SETUP.md (Phase 2) can document it precisely for a new user.
