# Nullafi Snowflake Connector — Release Plan

## Current status

The reusable connector is implemented and has passed local automated tests and
a clean-environment Snowflake validation. The supported installation entry point
is [`snowflake/install_connector.sql`](snowflake/install_connector.sql). It creates a
configuration-driven, insert-only pipeline that reads a Snowflake stream,
queues record IDs durably, sends configured fields to Nullafi, and records
results, recoverable errors, run metrics, and task failures.

The repository is ready for controlled use in a non-production environment. It
is **not yet signed off for production**: the remaining work below must be
completed and evidenced for the target account, data classification, and
Nullafi policy.

## Completed delivery scope

- [x] Local Nullafi client, synthetic data, and unit tests.
- [x] Snowflake external-access connectivity, secret binding, and `/scan`
  smoke test using synthetic data.
- [x] Batch processing with idempotent output writes, per-row error recording,
  and run metrics.
- [x] Stream-backed, durable ID-only queue that preserves work across bounded
  or failed runs.
- [x] User-managed Snowflake tasks, task-failure capture, and pipeline alerts.
- [x] Parameterized installer with source/configuration validation and tasks
  intentionally suspended after installation.
- [x] Clean-environment validation: installation, first processing run, idle
  run, scheduled processing, and monitoring path.
- [x] Local automated test suite (`venv/bin/python -m pytest -q`).

## Production-readiness plan

Complete every applicable item before enabling the scheduled tasks for
production. Record the evidence, owner, date, and target environment in the
release ticket or operational runbook.

### 1. Security and secret management

- [ ] Rotate the API key used during validation; create the production key with
  only the Nullafi scanning permissions it needs.
- [ ] Insert the new key only through a private Snowflake worksheet or an
  approved secret-management workflow; never commit it or paste it into a
  shared query.
- [ ] Search Snowflake query history for a short, non-sensitive key fragment as
  described in [`SETUP.md`](SETUP.md). If exposure is found, revoke/rotate the
  key, replace the Snowflake Secret, and document the incident.
- [ ] Verify the connector role follows least privilege: source `SELECT`, only
  required DML/create privileges in the connector and output schemas, warehouse
  `USAGE`, and only the required account-level integration privilege.
- [ ] Review who can read connector tables, especially the output and error
  tables. Keep `STORE_RAW_RESPONSES = FALSE` unless a time-bounded,
  access-controlled diagnostic is approved.
- [ ] Confirm the Nullafi network rule and the external-access integration allow
  only the approved endpoint and bound secret.

### 2. Nullafi contract validation

- [ ] Measure and document the maximum safe individual field length, total
  request size, and number of values/arguments accepted by the production
  Nullafi `/scan` endpoint and policy. Test boundary, one-over-boundary, and
  mixed-size requests with synthetic data.
- [ ] Set `MAX_FIELD_CHARACTERS` and `MAX_VALUES_PER_REQUEST` from those measured
  limits, with safety headroom. Do not rely on the current conservative defaults
  (`1000` characters and `20` values) as production limits.
- [ ] Validate the response contract for every production policy: unchanged
  values, obfuscated values, nulls, malformed responses, 4xx/5xx errors,
  timeouts, rate limiting, and partial batch failures.
- [ ] Confirm that the configured namespace and Nullafi rules protect every
  required data type. The current connector does not persist entity types unless
  the API contract supplies them.
- [ ] Agree retry, backoff, and rate-limit behavior with Nullafi. Document the
  chosen retry operator procedure; this release records failed work for retry
  but does not implement automatic exponential backoff.

### 3. Data and operational validation

- [ ] Validate the actual source table has a non-null, immutable, unique source
  key and that all configured scan columns are correct for the data contract.
- [ ] Confirm the insert-only behavior is acceptable. Updates are not rescanned;
  source deletions queued before processing are recorded as skipped; historical
  result rows are retained.
- [ ] Define output/error/run-log retention, access controls, backup/recovery,
  and deletion procedures. Protected values and response bodies may still be
  sensitive data.
- [ ] Exercise recovery: temporary Nullafi outage, task suspension after three
  failures, failed-row retry, source deletion while queued, and task resumption.
- [ ] Load test with representative row counts, field sizes, concurrency, and
  warehouse size. Set task schedule, `MAX_ROWS`, warehouse sizing, and cost
  alerts from the results.
- [ ] Add external alert delivery or a monitored dashboard for
  `NULLAFI_CONNECTOR_PIPELINE_ALERTS` and
  `NULLAFI_CONNECTOR_TASK_FAILURE_LOG`; table-only monitoring is insufficient
  unless an owner and response SLA are documented.
- [ ] Create an operational runbook covering daily health checks, failure
  triage, retry criteria, secret rotation, policy changes, and rollback.

### 4. Release and lifecycle controls

- [ ] Re-run the full automated suite and a clean-environment installation with
  the release candidate; retain the resulting run IDs and validation results.
- [ ] Review Snowflake Python runtime/package availability and pin or test the
  supported dependency behavior for the target account.
- [ ] Review SQL and operational permissions with the security/data-governance
  owners; obtain approval for external transmission of the selected fields.
- [ ] Define change management for schema changes, Nullafi policy changes,
  connector upgrades, and emergency task suspension.
- [ ] Tag and publish a versioned release with release notes, compatibility
  requirements, known limitations, and rollback instructions.
- [ ] Convert to a Snowflake Native App.
