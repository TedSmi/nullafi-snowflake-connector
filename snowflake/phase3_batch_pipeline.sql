-- Phase 3: a rerun-safe sample pipeline from a Snowflake input table through
-- Nullafi and into output, error, and run-metric tables.
-- Phase 4 extends this sample with a stream-backed work queue so normal runs
-- process only newly inserted source records.
--
-- This is deliberately a self-contained demonstration with synthetic data and
-- fixed table names. Phase 6 will replace these names and column choices with
-- the connector configuration table described in DESIGN.md.
--
-- Prerequisite: run snowflake/phase2_connectivity.sql first. It creates the
-- NULLAFI_API_KEY secret and NULLAFI_EXTERNAL_ACCESS_INTEGRATION used below.
-- Never replace a placeholder or add a real API key to this file.

-- ---------------------------------------------------------------------------
-- 1. Sample source and connector operational tables
-- ---------------------------------------------------------------------------
-- The source table intentionally contains only fake values from Phase 1. In a
-- real pipeline, upstream ingestion owns the source records; this connector
-- owns only PROCESSING_STATUS and its own output/error/run-log tables.
CREATE OR REPLACE TABLE NULLAFI_PHASE3_SAMPLE_INPUT (
  RECORD_ID STRING NOT NULL,
  EMAIL STRING,
  SSN STRING,
  CREDIT_CARD STRING,
  FULL_NAME STRING,
  NOTES STRING,
  PROCESSING_STATUS STRING NOT NULL DEFAULT 'PENDING',
  LAST_PROCESSED_AT TIMESTAMP_TZ,
  LAST_ERROR_MESSAGE STRING,
  CONSTRAINT NULLAFI_PHASE3_SAMPLE_INPUT_PK PRIMARY KEY (RECORD_ID)
)
COMMENT = 'Synthetic Phase 3 source records. PROCESSING_STATUS is owned by the connector.';

-- This seed data mirrors data/fake_sensitive_data.json. It is safe to keep in
-- source control because every value is synthetic.
INSERT INTO NULLAFI_PHASE3_SAMPLE_INPUT (
  RECORD_ID, EMAIL, SSN, CREDIT_CARD, FULL_NAME, NOTES
)
VALUES
  (
    'cust_001',
    'alex.test@example.com',
    '122-12-8348',
    '4111111111111111',
    'Alex Example',
    'Customer asked whether their invoice could be sent by email.'
  ),
  (
    'cust_002',
    'billing@example.org',
    '078-05-1120',
    '5555555555554444',
    'Jordan Sample',
    NULL
  ),
  (
    'cust_003',
    '',
    'not-an-ssn',
    'not-a-card',
    'No Sensitive Match',
    'Ordinary account note with no planted SSN or card.'
  );

-- This is a standard stream rather than an append-only stream so its behavior
-- is explicit and inspectable: Snowflake records inserts, updates, and
-- deletes. The Phase 4 consumer intentionally queues only plain INSERT events
-- (METADATA$ACTION = 'INSERT' and METADATA$ISUPDATE = FALSE). See DESIGN.md
-- for the chosen insert-triggered update/delete policy.
--
-- SHOW_INITIAL_ROWS makes this self-contained sample process the three seeded
-- records on its first call. In an existing production table, omit it when the
-- desired behavior is to process only rows inserted after stream creation.
CREATE OR REPLACE STREAM NULLAFI_PHASE4_INPUT_STREAM
  ON TABLE NULLAFI_PHASE3_SAMPLE_INPUT
  SHOW_INITIAL_ROWS = TRUE
COMMENT = 'Captures input-table changes; Phase 4 queues only non-update inserts.';

-- A stream offset is advanced only by a committed DML statement that consumes
-- the stream. This durable, ID-only queue is that DML target. It holds no
-- source field values, so plaintext continues to live only in the source
-- table (and the temporary raw API diagnostics already documented below).
CREATE OR REPLACE TABLE NULLAFI_PHASE4_WORK_QUEUE (
  STREAM_ROW_ID STRING NOT NULL,
  SOURCE_RECORD_ID STRING NOT NULL,
  QUEUE_STATUS STRING NOT NULL DEFAULT 'PENDING',
  QUEUED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  LAST_ATTEMPT_AT TIMESTAMP_TZ,
  LAST_ERROR_MESSAGE STRING,
  CONSTRAINT NULLAFI_PHASE4_WORK_QUEUE_PK PRIMARY KEY (STREAM_ROW_ID)
)
COMMENT = 'Durable, insert-triggered work queue populated from NULLAFI_PHASE4_INPUT_STREAM.';

-- One output row exists for each source-row/column pair. A MERGE in the
-- procedure makes this natural key rerun-safe even though Snowflake does not
-- enforce PRIMARY KEY constraints on standard tables.
CREATE OR REPLACE TABLE NULLAFI_PHASE3_SCAN_OUTPUT (
  SOURCE_RECORD_ID STRING NOT NULL,
  SCAN_COLUMN STRING NOT NULL,
  OBFUSCATED_VALUE STRING,
  DETECTED_ENTITY_TYPES ARRAY,
  VALUE_CHANGED BOOLEAN,
  SCAN_STATUS STRING NOT NULL,
  SCANNED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  RUN_ID STRING NOT NULL,
  RAW_API_RESPONSE VARIANT,
  CONSTRAINT NULLAFI_PHASE3_SCAN_OUTPUT_PK PRIMARY KEY (SOURCE_RECORD_ID, SCAN_COLUMN)
)
COMMENT = 'Per-field Nullafi results. Raw responses are temporary diagnostics and can contain sensitive values.';

-- Failures retain operational metadata and the service response when present,
-- but never store request headers, API keys, or request payload values.
CREATE OR REPLACE TABLE NULLAFI_PHASE3_ERROR_LOG (
  ERROR_ID STRING NOT NULL,
  RUN_ID STRING NOT NULL,
  SOURCE_RECORD_ID STRING NOT NULL,
  BATCH_ID INTEGER,
  ERROR_STAGE STRING NOT NULL,
  HTTP_STATUS_CODE INTEGER,
  ERROR_MESSAGE STRING NOT NULL,
  RESPONSE_BODY VARIANT,
  OCCURRED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Dead-letter log for recoverable Nullafi batch and field failures.';

CREATE OR REPLACE TABLE NULLAFI_PHASE3_RUN_LOG (
  RUN_ID STRING NOT NULL,
  STARTED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  FINISHED_AT TIMESTAMP_TZ,
  RUN_STATUS STRING NOT NULL,
  ROWS_SELECTED INTEGER NOT NULL DEFAULT 0,
  ROWS_PROCESSED INTEGER NOT NULL DEFAULT 0,
  ROWS_FAILED INTEGER NOT NULL DEFAULT 0,
  OUTPUT_ROWS_WRITTEN INTEGER NOT NULL DEFAULT 0,
  API_CALLS INTEGER NOT NULL DEFAULT 0,
  API_CALL_FAILURES INTEGER NOT NULL DEFAULT 0,
  DURATION_MS INTEGER,
  FAILURE_MESSAGE STRING,
  CONSTRAINT NULLAFI_PHASE3_RUN_LOG_PK PRIMARY KEY (RUN_ID)
)
COMMENT = 'One operational-metrics row per procedure invocation.';

-- ---------------------------------------------------------------------------
-- 2. Batch stored procedure
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE NULLAFI_PROCESS_BATCH(
    MAX_ROWS INTEGER DEFAULT 100,
    RETRY_FAILED BOOLEAN DEFAULT FALSE,
    NULLAFI_NAMESPACE STRING DEFAULT 'dlp test',
    NULLAFI_BASE_URL STRING DEFAULT 'https://openflow.nullafi.net/api',
    NULLAFI_SCAN_PATH STRING DEFAULT '/scan'
  )
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.10'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (NULLAFI_EXTERNAL_ACCESS_INTEGRATION)
  SECRETS = ('nullafi_api_key' = NULLAFI_API_KEY)
  EXECUTE AS OWNER
AS
$$
import json
import uuid

import _snowflake
import requests


# The API's published rate and payload limits are still unknown. These values
# are intentionally conservative until Phase 1 can measure a live rule path.
MAX_FIELD_CHARACTERS = 1000
MAX_VALUES_PER_REQUEST = 20
SCANNED_COLUMNS = ("EMAIL", "SSN", "CREDIT_CARD", "FULL_NAME", "NOTES")
HTTP_SESSION = requests.Session()


def _join_url(base_url, scan_path):
    base = base_url.rstrip("/")
    path = scan_path if scan_path.startswith("/") else "/" + scan_path
    return base + path


def _compact_json(value):
    """Serialize values for PARSE_JSON bind variables without logging them."""
    return json.dumps(value, separators=(",", ":"), default=str)


def _execute(session, statement, params=None):
    """Execute DML eagerly so API work is not acknowledged before it is saved."""
    return session.sql(statement, params=params or []).collect()


def _merge_output(session, run_id, record_id, column, returned_value, changed, status, response):
    # MERGE, rather than INSERT, is the idempotency boundary. If a procedure is
    # rerun after a client-side interruption, the source/column result is updated
    # in place instead of creating another output row.
    # Snowpark's bound parameters do not reliably translate Python None into a
    # nullable BOOLEAN here: it can arrive as the string "None" and fail the
    # DML. Emit a SQL NULL literal only for skipped-null inputs instead.
    changed_expression = "NULL" if changed is None else "?"
    update_params = [record_id, column, returned_value]
    if changed is not None:
        update_params.append(changed)
    update_params.extend([status, run_id, _compact_json(response)])

    insert_params = [record_id, column, returned_value]
    if changed is not None:
        insert_params.append(changed)
    insert_params.extend([status, run_id, _compact_json(response)])
    _execute(
        session,
        f"""
        MERGE INTO NULLAFI_PHASE3_SCAN_OUTPUT AS target
        USING (SELECT ? AS source_record_id, ? AS scan_column) AS source
          ON target.SOURCE_RECORD_ID = source.source_record_id
         AND target.SCAN_COLUMN = source.scan_column
        WHEN MATCHED THEN UPDATE SET
          OBFUSCATED_VALUE = ?,
          DETECTED_ENTITY_TYPES = NULL,
          VALUE_CHANGED = {changed_expression},
          SCAN_STATUS = ?,
          SCANNED_AT = CURRENT_TIMESTAMP(),
          RUN_ID = ?,
          RAW_API_RESPONSE = PARSE_JSON(?)
        WHEN NOT MATCHED THEN INSERT (
          SOURCE_RECORD_ID, SCAN_COLUMN, OBFUSCATED_VALUE,
          DETECTED_ENTITY_TYPES, VALUE_CHANGED, SCAN_STATUS, SCANNED_AT,
          RUN_ID, RAW_API_RESPONSE
        ) VALUES (?, ?, ?, NULL, {changed_expression}, ?, CURRENT_TIMESTAMP(), ?, PARSE_JSON(?))
        """,
        update_params + insert_params,
    )


def _write_error(session, run_id, record_id, batch_id, stage, message, status_code=None, body=None):
    # Do not add request values or headers here. An error log must be useful for
    # recovery without becoming another store of plaintext sensitive data.
    # As with nullable booleans in _merge_output, emit SQL NULL for absent
    # numeric metadata. Binding Python None can otherwise become the strings
    # "None" and fail inserts into INTEGER columns in Snowpark.
    batch_id_expression = "NULL" if batch_id is None else "?"
    status_code_expression = "NULL" if status_code is None else "?"
    params = [run_id, record_id]
    if batch_id is not None:
        params.append(batch_id)
    params.append(stage)
    if status_code is not None:
        params.append(status_code)
    params.extend([message[:2000], _compact_json(body)])
    _execute(
        session,
        f"""
        INSERT INTO NULLAFI_PHASE3_ERROR_LOG (
          ERROR_ID, RUN_ID, SOURCE_RECORD_ID, BATCH_ID, ERROR_STAGE,
          HTTP_STATUS_CODE, ERROR_MESSAGE, RESPONSE_BODY
        )
        SELECT UUID_STRING(), ?, ?, {batch_id_expression}, ?, {status_code_expression}, ?, PARSE_JSON(?)
        """,
        params,
    )


def _chunks_by_record(items_by_record):
    """Keep one source record intact while limiting outbound field values."""
    batches = []
    current = []
    for record_items in items_by_record:
        if current and len(current) + len(record_items) > MAX_VALUES_PER_REQUEST:
            batches.append(current)
            current = []
        current.extend(record_items)
    if current:
        batches.append(current)
    return batches


def _consume_insert_stream_rows(session):
    """Durably enqueue inserts and advance the stream only through DML.

    This MERGE is deliberately performed before the external API work. A
    committed DML statement consumes all currently visible stream records; the
    WHERE clause enqueues only source inserts that are not update-images. Any
    queued row that is not processed in this invocation remains durable for a
    later run, including after an unexpected procedure failure.
    """
    _execute(
        session,
        """
        MERGE INTO NULLAFI_PHASE4_WORK_QUEUE AS target
        USING (
          SELECT METADATA$ROW_ID AS STREAM_ROW_ID, RECORD_ID AS SOURCE_RECORD_ID
          FROM NULLAFI_PHASE4_INPUT_STREAM
          WHERE METADATA$ACTION = 'INSERT'
            AND METADATA$ISUPDATE = FALSE
        ) AS source
          ON target.STREAM_ROW_ID = source.STREAM_ROW_ID
        WHEN NOT MATCHED THEN INSERT (STREAM_ROW_ID, SOURCE_RECORD_ID, QUEUE_STATUS)
          VALUES (source.STREAM_ROW_ID, source.SOURCE_RECORD_ID, 'PENDING')
        """,
    )


def _skip_deleted_queued_rows(session, eligible_statuses):
    """Do not send a record that was deleted after it entered the queue."""
    _execute(
        session,
        f"""
        UPDATE NULLAFI_PHASE4_WORK_QUEUE AS queue
        SET QUEUE_STATUS = 'SKIPPED_SOURCE_DELETED',
            LAST_ATTEMPT_AT = CURRENT_TIMESTAMP(),
            LAST_ERROR_MESSAGE = 'Source record was deleted before scanning; no API request was made.'
        WHERE QUEUE_STATUS IN ({eligible_statuses})
          AND NOT EXISTS (
            SELECT 1
            FROM NULLAFI_PHASE3_SAMPLE_INPUT AS source
            WHERE source.RECORD_ID = queue.SOURCE_RECORD_ID
          )
        """,
    )


def _update_queue_status(session, stream_row_id, status, error_message=None):
    """Record a durable processing outcome without binding nullable strings."""
    error_expression = "NULL" if error_message is None else "?"
    params = [status]
    if error_message is not None:
        params.append(error_message[:2000])
    params.append(stream_row_id)
    _execute(
        session,
        f"""
        UPDATE NULLAFI_PHASE4_WORK_QUEUE
        SET QUEUE_STATUS = ?,
            LAST_ATTEMPT_AT = CURRENT_TIMESTAMP(),
            LAST_ERROR_MESSAGE = {error_expression}
        WHERE STREAM_ROW_ID = ?
        """,
        params,
    )


def run(session, max_rows, retry_failed, nullafi_namespace, nullafi_base_url, nullafi_scan_path):
    if max_rows is None or int(max_rows) < 1 or int(max_rows) > 10000:
        raise ValueError("MAX_ROWS must be between 1 and 10000")

    run_id = str(uuid.uuid4())
    max_rows = int(max_rows)
    metrics = {
        "rows_selected": 0,
        "rows_processed": 0,
        "rows_failed": 0,
        "output_rows_written": 0,
        "api_calls": 0,
        "api_call_failures": 0,
    }

    _execute(
        session,
        "INSERT INTO NULLAFI_PHASE3_RUN_LOG (RUN_ID, RUN_STATUS) VALUES (?, 'RUNNING')",
        [run_id],
    )

    try:
        eligible_statuses = "'PENDING', 'FAILED'" if retry_failed else "'PENDING'"
        # This MERGE is the stream-consumption boundary. A SELECT alone would
        # repeatedly return the same changes and would not move the offset.
        _consume_insert_stream_rows(session)
        _skip_deleted_queued_rows(session, eligible_statuses)

        # Object names and column names are constants in this Phase 3/4 sample;
        # Phase 6 will validate and parameterize them through a config table.
        records = session.sql(
            f"""
            SELECT queue.STREAM_ROW_ID, source.RECORD_ID, source.EMAIL, source.SSN,
                   source.CREDIT_CARD, source.FULL_NAME, source.NOTES
            FROM NULLAFI_PHASE4_WORK_QUEUE AS queue
            JOIN NULLAFI_PHASE3_SAMPLE_INPUT AS source
              ON source.RECORD_ID = queue.SOURCE_RECORD_ID
            WHERE queue.QUEUE_STATUS IN ({eligible_statuses})
            ORDER BY queue.QUEUED_AT, queue.STREAM_ROW_ID
            LIMIT {max_rows}
            """
        ).collect()
        metrics["rows_selected"] = len(records)

        # Each item has an opaque payload key. This allows one HTTP body to hold
        # fields from many source records without colliding on names such as SSN.
        items_by_record = []
        record_errors = {record["RECORD_ID"]: [] for record in records}
        payload_index = 0
        for record in records:
            record_id = record["RECORD_ID"]
            record_items = []
            for column in SCANNED_COLUMNS:
                value = record[column]
                if value is None:
                    _merge_output(
                        session, run_id, record_id, column, None, None,
                        "SKIPPED_NULL", {"skipped": "null input; no API call made"},
                    )
                    metrics["output_rows_written"] += 1
                    continue

                text_value = str(value)
                if len(text_value) > MAX_FIELD_CHARACTERS:
                    message = (
                        f"{column} exceeds the conservative {MAX_FIELD_CHARACTERS}-character "
                        "limit; it was not sent to Nullafi."
                    )
                    record_errors[record_id].append(message)
                    _write_error(session, run_id, record_id, None, "FIELD_VALIDATION", message)
                    continue

                payload_index += 1
                record_items.append(
                    {
                        "payload_key": f"v_{payload_index}",
                        "record_id": record_id,
                        "column": column,
                        "value": text_value,
                    }
                )
            if record_items:
                items_by_record.append(record_items)

        endpoint = _join_url(nullafi_base_url, nullafi_scan_path)
        api_key = _snowflake.get_generic_secret_string("nullafi_api_key")
        for batch_id, batch_items in enumerate(_chunks_by_record(items_by_record), start=1):
            payload = {item["payload_key"]: item["value"] for item in batch_items}
            metrics["api_calls"] += 1
            # Reset these on every iteration. Otherwise a transport failure after
            # a prior successful request could accidentally log stale response
            # metadata from that earlier batch.
            response = None
            body = None
            try:
                response = HTTP_SESSION.post(
                    endpoint,
                    params={"namespace": nullafi_namespace},
                    headers={
                        "Authorization": "Bearer " + api_key,
                        "Content-Type": "application/json",
                        "Accept": "application/json",
                    },
                    json=payload,
                    timeout=20,
                )
                try:
                    body = response.json()
                except ValueError:
                    body = {"non_json_response": response.text[:500]}

                if not (200 <= response.status_code < 300):
                    raise RuntimeError(f"Nullafi returned HTTP {response.status_code}")
                if not isinstance(body, dict):
                    raise RuntimeError("Nullafi returned a successful non-object JSON response")
            except (requests.RequestException, RuntimeError) as exc:
                # A failed HTTP batch is recoverable: mark only its source rows
                # FAILED, dead-letter them, and let later batches continue.
                metrics["api_call_failures"] += 1
                status_code = getattr(response, "status_code", None)
                body = body if body is not None else {"error": str(exc)}
                message = str(exc)
                for record_id in sorted({item["record_id"] for item in batch_items}):
                    record_errors[record_id].append(message)
                    _write_error(
                        session, run_id, record_id, batch_id, "NULLAFI_BATCH", message,
                        status_code, body,
                    )
                continue

            # A valid batch response can still omit an individual key. Treat that
            # field as an isolated failure instead of accepting a silent loss.
            for item in batch_items:
                payload_key = item["payload_key"]
                if payload_key not in body:
                    message = f"Nullafi response omitted payload key {payload_key}"
                    record_errors[item["record_id"]].append(message)
                    _write_error(
                        session, run_id, item["record_id"], batch_id,
                        "RESPONSE_VALIDATION", message, response.status_code, body,
                    )
                    continue

                returned_value = body[payload_key]
                returned_text = None if returned_value is None else str(returned_value)
                changed = returned_text != item["value"]
                # Until the dashboard rule is enabled, an unchanged response is
                # recorded as NO_MATCH rather than treated as an HTTP failure.
                status = "SUCCESS" if changed else "NO_MATCH"
                _merge_output(
                    session, run_id, item["record_id"], item["column"],
                    returned_text, changed, status, body,
                )
                metrics["output_rows_written"] += 1

        for record in records:
            record_id = record["RECORD_ID"]
            stream_row_id = record["STREAM_ROW_ID"]
            errors = record_errors[record_id]
            if errors:
                metrics["rows_failed"] += 1
                _update_queue_status(session, stream_row_id, "FAILED", "; ".join(errors))
                _execute(
                    session,
                    """
                    UPDATE NULLAFI_PHASE3_SAMPLE_INPUT
                    SET PROCESSING_STATUS = 'FAILED',
                        LAST_PROCESSED_AT = CURRENT_TIMESTAMP(),
                        LAST_ERROR_MESSAGE = ?
                    WHERE RECORD_ID = ?
                    """,
                    ["; ".join(errors)[:2000], record_id],
                )
            else:
                metrics["rows_processed"] += 1
                _update_queue_status(session, stream_row_id, "PROCESSED")
                _execute(
                    session,
                    """
                    UPDATE NULLAFI_PHASE3_SAMPLE_INPUT
                    SET PROCESSING_STATUS = 'PROCESSED',
                        LAST_PROCESSED_AT = CURRENT_TIMESTAMP(),
                        LAST_ERROR_MESSAGE = NULL
                    WHERE RECORD_ID = ?
                    """,
                    [record_id],
                )

        _execute(
            session,
            """
            UPDATE NULLAFI_PHASE3_RUN_LOG
            SET FINISHED_AT = CURRENT_TIMESTAMP(), RUN_STATUS = 'SUCCESS',
                ROWS_SELECTED = ?, ROWS_PROCESSED = ?, ROWS_FAILED = ?,
                OUTPUT_ROWS_WRITTEN = ?, API_CALLS = ?, API_CALL_FAILURES = ?,
                DURATION_MS = DATEDIFF('millisecond', STARTED_AT, CURRENT_TIMESTAMP())
            WHERE RUN_ID = ?
            """,
            [
                metrics["rows_selected"], metrics["rows_processed"], metrics["rows_failed"],
                metrics["output_rows_written"], metrics["api_calls"], metrics["api_call_failures"],
                run_id,
            ],
        )
        return {"run_id": run_id, "status": "SUCCESS", **metrics}
    except Exception as exc:
        # Unexpected Snowflake/DML/configuration failures remain visible to the
        # caller, but the run log is still closed with the safe exception text.
        _execute(
            session,
            """
            UPDATE NULLAFI_PHASE3_RUN_LOG
            SET FINISHED_AT = CURRENT_TIMESTAMP(), RUN_STATUS = 'FAILED',
                ROWS_SELECTED = ?, ROWS_PROCESSED = ?, ROWS_FAILED = ?,
                OUTPUT_ROWS_WRITTEN = ?, API_CALLS = ?, API_CALL_FAILURES = ?,
                DURATION_MS = DATEDIFF('millisecond', STARTED_AT, CURRENT_TIMESTAMP()),
                FAILURE_MESSAGE = ?
            WHERE RUN_ID = ?
            """,
            [
                metrics["rows_selected"], metrics["rows_processed"], metrics["rows_failed"],
                metrics["output_rows_written"], metrics["api_calls"], metrics["api_call_failures"],
                str(exc)[:2000], run_id,
            ],
        )
        raise
$$;

-- ---------------------------------------------------------------------------
-- 3. Validation queries
-- ---------------------------------------------------------------------------
-- Happy path: after an active Nullafi rule is configured, all three records
-- should become PROCESSED and the output count should be 15 (3 x 5 columns).
CALL NULLAFI_PROCESS_BATCH();

SELECT PROCESSING_STATUS, COUNT(*) AS ROW_COUNT
FROM NULLAFI_PHASE3_SAMPLE_INPUT
GROUP BY PROCESSING_STATUS
ORDER BY PROCESSING_STATUS;

SELECT COUNT(*) AS OUTPUT_ROW_COUNT
FROM NULLAFI_PHASE3_SCAN_OUTPUT;

SELECT *
FROM NULLAFI_PHASE3_ERROR_LOG
ORDER BY OCCURRED_AT DESC;

SELECT *
FROM NULLAFI_PHASE3_RUN_LOG
ORDER BY STARTED_AT DESC;

-- Rerun safety: the default call processes PENDING rows only. After a
-- successful first run this returns zero selected/processed rows and leaves
-- the output row count unchanged. Failed rows require an explicit retry.
CALL NULLAFI_PROCESS_BATCH();

-- Failure-path test (run only after the normal test): first reset the synthetic
-- rows to PENDING, then use a malformed endpoint. This reliably exercises the
-- recoverable transport-error path without changing the API key or Nullafi.
-- UPDATE NULLAFI_PHASE3_SAMPLE_INPUT
-- SET PROCESSING_STATUS = 'PENDING', LAST_ERROR_MESSAGE = NULL
-- WHERE RECORD_ID IN ('cust_001', 'cust_002', 'cust_003');
-- CALL NULLAFI_PROCESS_BATCH(100, FALSE, 'dlp test', 'not-a-valid-url', '/scan');
--
-- To intentionally retry recoverable failures without resetting them:
-- CALL NULLAFI_PROCESS_BATCH(100, TRUE);

-- ---------------------------------------------------------------------------
-- 4. Phase 4 stream validation
-- ---------------------------------------------------------------------------
-- New-row test: this INSERT is captured by NULLAFI_PHASE4_INPUT_STREAM. The
-- next call first merges the stream into the durable work queue, then scans
-- only this new row. Its return value should report ROWS_SELECTED = 1.
INSERT INTO NULLAFI_PHASE3_SAMPLE_INPUT (
  RECORD_ID, EMAIL, SSN, CREDIT_CARD, FULL_NAME, NOTES
)
VALUES (
  'cust_004',
  'new.customer@example.net',
  '987-65-4321',
  '4242424242424242',
  'New Customer',
  'Synthetic row inserted after the stream was created.'
);

CALL NULLAFI_PROCESS_BATCH();

SELECT SOURCE_RECORD_ID, QUEUE_STATUS, QUEUED_AT, LAST_ATTEMPT_AT
FROM NULLAFI_PHASE4_WORK_QUEUE
ORDER BY QUEUED_AT, SOURCE_RECORD_ID;

-- Idle-run test: there are no pending queue rows and only the connector's own
-- source-status updates in the stream. The DML stream-consumption step ignores
-- those update images, so this returns ROWS_SELECTED = 0 without an error.
CALL NULLAFI_PROCESS_BATCH();
