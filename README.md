# nullafi-snowflake-connector

A Snowflake-native connector that routes data through Nullafi for sensitive-data
detection and protection before it continues through a pipeline.

**Status:** Phase 1 complete — local proof of concept ready for commit

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
