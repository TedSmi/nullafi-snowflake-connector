# nullafi-snowflake-connector

A Snowflake-native connector that routes data through Nullafi for sensitive-data
detection and protection before it continues through a pipeline.

**Status:** Phase 2 implemented locally — live Snowflake validation blocked on trial-account external access

## Phase 2: Snowflake Connectivity

Phase 2 adds the Snowflake-side proof that a Python stored procedure can reach
Nullafi through Snowflake external network access. The implementation lives in
`snowflake/phase2_connectivity.sql` and the runbook lives in `SETUP.md`.

Snowflake trial accounts may fail with:

```text
SQL compilation error: External access is not supported for trial accounts.
```

That is an account limitation, not a connector bug. The repo-side Phase 2
artifacts can still be reviewed and tested locally, but the live Snowflake ->
Nullafi proof requires external access to be enabled on the Snowflake account.

### What Phase 2 Added

- A Snowflake `NETWORK RULE` scoped to `openflow.nullafi.net`.
- A Snowflake `GENERIC_STRING` secret for the Nullafi API key.
- An `EXTERNAL ACCESS INTEGRATION` binding the network rule and secret.
- A minimal Python stored procedure, `NULLAFI_PHASE2_CONNECTIVITY_TEST`, that
  calls Nullafi's `/scan` endpoint with one synthetic value.
- Static tests that verify the setup SQL keeps only a placeholder API key in the
  repository.

### Run In Snowflake

Open `snowflake/phase2_connectivity.sql` in a private Snowflake worksheet,
choose your role/warehouse/database/schema, replace the API-key placeholder in
the worksheet only, and run the script.

The smoke test is:

```sql
CALL NULLAFI_PHASE2_CONNECTIVITY_TEST();
```

Expected success shape:

```json
{
  "ok": true,
  "status_code": 200,
  "changed": true
}
```

`changed` may be `false` until a dashboard rule is attached to the
namespace/application; a 200 response is the Phase 2 connectivity proof.

See `SETUP.md` for privilege notes, troubleshooting, and the query-history check
for secret exposure.

## Phase 2.5: Get Account And Verify Phase 2

The current Snowflake trial account cannot complete the live connectivity test
because external network access is disabled for trial accounts. To finish the
Snowflake proof later, use one of these paths:

- Ask Snowflake to enable external network access on the trial account.
- Convert the trial to a non-trial account.
- Use another Snowflake account where external network access is already enabled.

Once an account supports external access, rerun `snowflake/phase2_connectivity.sql`
from `SETUP.md`. Phase 2.5 is complete when:

- `NULLAFI_API_NETWORK_RULE`, `NULLAFI_API_KEY`, and
  `NULLAFI_EXTERNAL_ACCESS_INTEGRATION` are created successfully.
- `CALL NULLAFI_PHASE2_CONNECTIVITY_TEST();` returns HTTP `200`.
- Query history does not expose the Nullafi API key in plaintext, or the key is
  rotated immediately if exposure is found.
- `PLAN.md` is updated to mark the live Snowflake validation items complete.

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
- The dashboard currently shows `Rule: (None)`, so `/scan` returns the SSN
  unchanged until a dashboard rule is attached to the app/namespace.

### Left For Later

- Configure the Nullafi dashboard so `dlp test` has an active SSN obfuscation
  rule. Once that is fixed, rerun `python src/phase1_poc.py` without
  `--allow-unchanged-expected`.
- Confirm the final obfuscated response shape after a real rule is applied.
- Run broader rate-limit and max-payload tests after obfuscation is working.
- Phase 2 starts Snowflake connectivity: Network Rule, Secret, External Access
  Integration, and a minimal stored procedure that calls Nullafi.
