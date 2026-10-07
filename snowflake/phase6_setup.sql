-- Nullafi Snowflake connector: reusable installer.
--
-- Run this file in a NEW, otherwise empty schema. It does not create or alter
-- the source table. It creates only objects whose names start NULLAFI_CONNECTOR.
-- Do not run the Phase 2-5 sample scripts in the same schema: they are a POC
-- with deliberately different, fixed object names.
--
-- Before executing, replace only the values in this parameter block. The API
-- key placeholder must be replaced in a private worksheet and never committed.

-- USE ROLE <ROLE_WITH_THE_PRIVILEGES_LISTED_IN_THE_README>;
-- USE WAREHOUSE <A_WAREHOUSE_FOR_COMPILING_PROCEDURES>;
-- USE DATABASE <CONNECTOR_DATABASE>;
-- USE SCHEMA <NEW_CONNECTOR_SCHEMA>;

-- SOURCE_TABLE and OUTPUT_TABLE must be one-, two-, or three-part *unquoted*
-- identifiers. The procedure normalizes each part to uppercase to prevent
-- configuration from being interpolated as executable SQL. SCAN_COLUMNS is a
-- JSON array of source columns. The source key need not be declared as a
-- Snowflake PRIMARY KEY, but its non-null values must uniquely identify rows.
SET NULLAFI_SOURCE_TABLE = 'APP_DB.RAW.CUSTOMERS';
SET NULLAFI_SOURCE_KEY_COLUMN = 'CUSTOMER_ID';
SET NULLAFI_SCAN_COLUMNS = '["EMAIL", "SSN", "NOTES"]';
SET NULLAFI_OUTPUT_TABLE = 'APP_DB.PROTECTED.NULLAFI_SCAN_OUTPUT';
SET NULLAFI_NAMESPACE = 'your Nullafi namespace';
SET NULLAFI_TASK_WAREHOUSE = 'YOUR_TASK_WAREHOUSE';
SET NULLAFI_TASK_SCHEDULE = '5 MINUTES';

-- Keep this conservative default unless Nullafi has supplied measured limits.
SET NULLAFI_MAX_FIELD_CHARACTERS = 1000;
SET NULLAFI_MAX_VALUES_PER_REQUEST = 20;
-- Raw responses can contain protected or plaintext data. Leave FALSE for the
-- normal production posture; enabling it is only for short-lived diagnostics.
SET NULLAFI_STORE_RAW_RESPONSES = FALSE;

-- This secret is intentionally connector-owned. Snowflake requires a procedure
-- to bind a secret at CREATE PROCEDURE time, so arbitrary per-row secret names
-- cannot safely be selected at runtime. Its fully qualified reference is still
-- retained in the configuration table as auditable configuration.
CREATE OR REPLACE SECRET NULLAFI_CONNECTOR_API_KEY
  TYPE = GENERIC_STRING
  SECRET_STRING = '<PASTE_NULLAFI_API_KEY_HERE>'
  COMMENT = 'Bearer token used only by the Nullafi connector procedure.';

CREATE OR REPLACE NETWORK RULE NULLAFI_CONNECTOR_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('openflow.nullafi.net')
  COMMENT = 'Restricts connector Python egress to the Nullafi API host.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION NULLAFI_CONNECTOR_EXTERNAL_ACCESS
  ALLOWED_NETWORK_RULES = (NULLAFI_CONNECTOR_API_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (NULLAFI_CONNECTOR_API_KEY)
  ENABLED = TRUE
  COMMENT = 'Permits this connector to call Nullafi using its bound secret.';

-- One config row is sufficient for an installed connector. A CONFIG_NAME key
-- leaves room for multiple independently configured procedures in a future
-- release without making a task ambiguous today.
CREATE OR REPLACE TABLE NULLAFI_CONNECTOR_CONFIG (
  CONFIG_NAME STRING NOT NULL,
  SOURCE_TABLE STRING NOT NULL,
  SOURCE_KEY_COLUMN STRING NOT NULL,
  SCAN_COLUMNS ARRAY NOT NULL,
  OUTPUT_TABLE STRING NOT NULL,
  NULLAFI_NAMESPACE STRING NOT NULL,
  API_SECRET_REFERENCE STRING NOT NULL,
  BASE_URL STRING NOT NULL DEFAULT 'https://openflow.nullafi.net/api',
  SCAN_PATH STRING NOT NULL DEFAULT '/scan',
  MAX_FIELD_CHARACTERS INTEGER NOT NULL,
  MAX_VALUES_PER_REQUEST INTEGER NOT NULL,
  STORE_RAW_RESPONSES BOOLEAN NOT NULL DEFAULT FALSE,
  UPDATE_POLICY STRING NOT NULL DEFAULT 'INSERT_ONLY',
  ENABLED BOOLEAN NOT NULL DEFAULT TRUE,
  CREATED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  UPDATED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT NULLAFI_CONNECTOR_CONFIG_PK PRIMARY KEY (CONFIG_NAME)
)
COMMENT = 'Configuration only; it never contains an API key or source values.';

INSERT INTO NULLAFI_CONNECTOR_CONFIG (
  CONFIG_NAME, SOURCE_TABLE, SOURCE_KEY_COLUMN, SCAN_COLUMNS, OUTPUT_TABLE,
  NULLAFI_NAMESPACE, API_SECRET_REFERENCE, MAX_FIELD_CHARACTERS,
  MAX_VALUES_PER_REQUEST, STORE_RAW_RESPONSES
)
SELECT
  'DEFAULT', $NULLAFI_SOURCE_TABLE, $NULLAFI_SOURCE_KEY_COLUMN,
  PARSE_JSON($NULLAFI_SCAN_COLUMNS), $NULLAFI_OUTPUT_TABLE,
  $NULLAFI_NAMESPACE, CURRENT_DATABASE() || '.' || CURRENT_SCHEMA() || '.NULLAFI_CONNECTOR_API_KEY',
  $NULLAFI_MAX_FIELD_CHARACTERS, $NULLAFI_MAX_VALUES_PER_REQUEST,
  $NULLAFI_STORE_RAW_RESPONSES;

-- The operational tables hold identifiers and results, not a copy of source
-- plaintext. OUTPUT_TABLE is the user-selected durable result destination.
-- Do not replace a pre-existing output table: it can already hold scan audit
-- history. The validator below checks that an existing table has this schema.
CREATE TABLE IF NOT EXISTS IDENTIFIER($NULLAFI_OUTPUT_TABLE) (
  CONFIG_NAME STRING NOT NULL,
  SOURCE_RECORD_ID STRING NOT NULL,
  SCAN_COLUMN STRING NOT NULL,
  OBFUSCATED_VALUE STRING,
  VALUE_CHANGED BOOLEAN,
  SCAN_STATUS STRING NOT NULL,
  SCANNED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  RUN_ID STRING NOT NULL,
  RAW_API_RESPONSE VARIANT,
  CONSTRAINT NULLAFI_CONNECTOR_OUTPUT_PK PRIMARY KEY (CONFIG_NAME, SOURCE_RECORD_ID, SCAN_COLUMN)
)
COMMENT = 'Per-field results from Nullafi. RAW_API_RESPONSE is NULL unless explicitly enabled.';

CREATE OR REPLACE STREAM NULLAFI_CONNECTOR_INPUT_STREAM
  ON TABLE IDENTIFIER($NULLAFI_SOURCE_TABLE)
COMMENT = 'Captures source changes. The connector queues plain INSERT events only.';

CREATE OR REPLACE TABLE NULLAFI_CONNECTOR_WORK_QUEUE (
  STREAM_ROW_ID STRING NOT NULL,
  SOURCE_RECORD_ID STRING NOT NULL,
  QUEUE_STATUS STRING NOT NULL DEFAULT 'PENDING',
  QUEUED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  LAST_ATTEMPT_AT TIMESTAMP_TZ,
  LAST_ERROR_MESSAGE STRING,
  CONSTRAINT NULLAFI_CONNECTOR_WORK_QUEUE_PK PRIMARY KEY (STREAM_ROW_ID)
)
COMMENT = 'Durable, ID-only queue. It protects unprocessed stream work from loss.';

CREATE OR REPLACE TABLE NULLAFI_CONNECTOR_ERROR_LOG (
  ERROR_ID STRING NOT NULL,
  RUN_ID STRING NOT NULL,
  SOURCE_RECORD_ID STRING,
  BATCH_ID INTEGER,
  ERROR_STAGE STRING NOT NULL,
  HTTP_STATUS_CODE INTEGER,
  ERROR_MESSAGE STRING NOT NULL,
  RESPONSE_BODY VARIANT,
  OCCURRED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT NULLAFI_CONNECTOR_ERROR_LOG_PK PRIMARY KEY (ERROR_ID)
)
COMMENT = 'Recoverable failures. It never stores request headers or request values.';

CREATE OR REPLACE TABLE NULLAFI_CONNECTOR_RUN_LOG (
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
  CONSTRAINT NULLAFI_CONNECTOR_RUN_LOG_PK PRIMARY KEY (RUN_ID)
);

CREATE OR REPLACE TABLE NULLAFI_CONNECTOR_TASK_FAILURE_LOG (
  TASK_QUERY_ID STRING NOT NULL,
  TASK_NAME STRING NOT NULL,
  TASK_STATE STRING NOT NULL,
  SCHEDULED_AT TIMESTAMP_LTZ,
  COMPLETED_AT TIMESTAMP_LTZ,
  ERROR_CODE STRING,
  ERROR_MESSAGE STRING,
  RECORDED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT NULLAFI_CONNECTOR_TASK_FAILURE_LOG_PK PRIMARY KEY (TASK_QUERY_ID)
);

CREATE OR REPLACE PROCEDURE NULLAFI_CONNECTOR_VALIDATE_CONFIG(CONFIG_NAME STRING DEFAULT 'DEFAULT')
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.10'
  PACKAGES = ('snowflake-snowpark-python')
  HANDLER = 'run'
  EXECUTE AS OWNER
AS
$$
import json
import re

PART = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")


def quoted_name(value, label, parts=(1, 2, 3)):
    """Accept only simple identifiers before placing config into SQL text."""
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string identifier")
    names = value.split(".")
    if len(names) not in parts or not all(PART.fullmatch(name) for name in names):
        raise ValueError(
            f"{label} must be a one-, two-, or three-part unquoted identifier; "
            "quoted names, spaces, and SQL expressions are not supported."
        )
    return ".".join('"' + name.upper() + '"' for name in names)


def scan_columns_as_list(value):
    """Normalize Snowflake ARRAY values returned as either lists or JSON text.

    Snowpark stored procedures can materialize an ARRAY result as JSON text,
    while local tests and other runtimes can supply a native Python list.
    Parsing both representations keeps the config-table contract stable.
    """
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError("SCAN_COLUMNS must contain valid JSON array text") from exc
    elif isinstance(value, tuple):
        value = list(value)
    if not isinstance(value, list) or not value or not all(isinstance(column, str) for column in value):
        raise ValueError("SCAN_COLUMNS must be a non-empty JSON array of source column names")
    return value


def run(session, config_name):
    rows = session.sql(
        "SELECT * FROM NULLAFI_CONNECTOR_CONFIG WHERE CONFIG_NAME = ?", [config_name]
    ).collect()
    if len(rows) != 1:
        raise ValueError(f"Configuration {config_name!r} does not exist; insert exactly one config row.")
    config = rows[0]
    source_table = quoted_name(config["SOURCE_TABLE"], "SOURCE_TABLE", (1, 2, 3))
    output_table = quoted_name(config["OUTPUT_TABLE"], "OUTPUT_TABLE", (1, 2, 3))
    key_column = quoted_name(config["SOURCE_KEY_COLUMN"], "SOURCE_KEY_COLUMN", (1,))
    scan_columns = scan_columns_as_list(config["SCAN_COLUMNS"])
    normalized_columns = [quoted_name(column, "SCAN_COLUMNS entry", (1,)) for column in scan_columns]
    if len(set(normalized_columns)) != len(normalized_columns):
        raise ValueError("SCAN_COLUMNS contains duplicate column names")
    if key_column in normalized_columns:
        raise ValueError("SOURCE_KEY_COLUMN must not also appear in SCAN_COLUMNS")
    if config["UPDATE_POLICY"] != "INSERT_ONLY":
        raise ValueError("UPDATE_POLICY currently supports only INSERT_ONLY")
    if not config["NULLAFI_NAMESPACE"].strip():
        raise ValueError("NULLAFI_NAMESPACE must not be empty")
    if not 1 <= int(config["MAX_FIELD_CHARACTERS"]) <= 100000:
        raise ValueError("MAX_FIELD_CHARACTERS must be between 1 and 100000")
    if not 1 <= int(config["MAX_VALUES_PER_REQUEST"]) <= 1000:
        raise ValueError("MAX_VALUES_PER_REQUEST must be between 1 and 1000")
    # DESC is both an existence check and a schema check. Use the normalized
    # returned names because Snowflake reports unquoted identifiers in uppercase.
    source_columns = {row["name"].upper() for row in session.sql(f"DESC TABLE {source_table}").collect()}
    requested = {name.replace('"', '') for name in [key_column] + normalized_columns}
    missing = sorted(requested - source_columns)
    if missing:
        raise ValueError("Source table is missing configured column(s): " + ", ".join(missing))
    output_columns = {row["name"].upper() for row in session.sql(f"DESC TABLE {output_table}").collect()}
    required_output = {
        "CONFIG_NAME", "SOURCE_RECORD_ID", "SCAN_COLUMN", "OBFUSCATED_VALUE",
        "VALUE_CHANGED", "SCAN_STATUS", "SCANNED_AT", "RUN_ID", "RAW_API_RESPONSE",
    }
    missing_output = sorted(required_output - output_columns)
    if missing_output:
        raise ValueError("Output table is missing connector column(s): " + ", ".join(missing_output))
    null_key = session.sql(f"SELECT 1 FROM {source_table} WHERE {key_column} IS NULL LIMIT 1").collect()
    if null_key:
        raise ValueError("SOURCE_KEY_COLUMN contains NULL values; it must be non-null and stable")
    duplicate_key = session.sql(
        f"SELECT {key_column}::STRING FROM {source_table} GROUP BY 1 HAVING COUNT(*) > 1 LIMIT 1"
    ).collect()
    if duplicate_key:
        raise ValueError("SOURCE_KEY_COLUMN is not unique in the source table")
    return {
        "ok": True,
        "config_name": config_name,
        "source_table": config["SOURCE_TABLE"],
        "output_table": config["OUTPUT_TABLE"],
        "source_key_column": config["SOURCE_KEY_COLUMN"],
        "scan_columns": scan_columns,
    }
$$;

CREATE OR REPLACE PROCEDURE NULLAFI_CONNECTOR_PROCESS(
    CONFIG_NAME STRING DEFAULT 'DEFAULT', MAX_ROWS INTEGER DEFAULT 100, RETRY_FAILED BOOLEAN DEFAULT FALSE
  )
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.10'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (NULLAFI_CONNECTOR_EXTERNAL_ACCESS)
  SECRETS = ('nullafi_api_key' = NULLAFI_CONNECTOR_API_KEY)
  EXECUTE AS OWNER
AS
$$
import json
import re
import uuid
import _snowflake
import requests

PART = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")
HTTP_SESSION = requests.Session()


def _name(value, label, parts=(1, 2, 3)):
    if not isinstance(value, str):
        raise ValueError(f"{label} must be a string identifier")
    values = value.split(".")
    if len(values) not in parts or not all(PART.fullmatch(value) for value in values):
        raise ValueError(f"{label} must be an unquoted Snowflake identifier, not SQL text")
    return ".".join('"' + value.upper() + '"' for value in values)


def _scan_columns_as_list(value):
    """Normalize a Snowflake ARRAY collected as JSON text or a native list."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ValueError("SCAN_COLUMNS must contain valid JSON array text") from exc
    elif isinstance(value, tuple):
        value = list(value)
    if not isinstance(value, list) or not value or not all(isinstance(column, str) for column in value):
        raise ValueError("SCAN_COLUMNS must be a non-empty JSON array of source column names")
    return value


def _execute(session, sql, params=None):
    return session.sql(sql, params=params or []).collect()


def _json(value):
    return json.dumps(value, separators=(",", ":"), default=str)


def _load_config(session, config_name):
    rows = session.sql("SELECT * FROM NULLAFI_CONNECTOR_CONFIG WHERE CONFIG_NAME = ? AND ENABLED", [config_name]).collect()
    if len(rows) != 1:
        raise ValueError(f"Enabled configuration {config_name!r} was not found")
    c = rows[0]
    source = _name(c["SOURCE_TABLE"], "SOURCE_TABLE")
    output = _name(c["OUTPUT_TABLE"], "OUTPUT_TABLE")
    key = _name(c["SOURCE_KEY_COLUMN"], "SOURCE_KEY_COLUMN", (1,))
    columns = _scan_columns_as_list(c["SCAN_COLUMNS"])
    scanned = [_name(column, "SCAN_COLUMNS entry", (1,)) for column in columns]
    if len(set(scanned)) != len(scanned) or key in scanned:
        raise ValueError("SCAN_COLUMNS must be unique and must not include SOURCE_KEY_COLUMN")
    if c["UPDATE_POLICY"] != "INSERT_ONLY":
        raise ValueError("Only INSERT_ONLY UPDATE_POLICY is currently supported")
    if not c["NULLAFI_NAMESPACE"].strip():
        raise ValueError("NULLAFI_NAMESPACE must not be empty")
    if not 1 <= int(c["MAX_FIELD_CHARACTERS"]) <= 100000 or not 1 <= int(c["MAX_VALUES_PER_REQUEST"]) <= 1000:
        raise ValueError("Configured batch limits are outside their supported range")
    source_columns = {row["name"].upper() for row in session.sql(f"DESC TABLE {source}").collect()}
    wanted = {x.replace('"', '') for x in [key] + scanned}
    missing = sorted(wanted - source_columns)
    if missing:
        raise ValueError("Source table is missing configured column(s): " + ", ".join(missing))
    output_columns = {row["name"].upper() for row in session.sql(f"DESC TABLE {output}").collect()}
    required_output = {"CONFIG_NAME", "SOURCE_RECORD_ID", "SCAN_COLUMN", "OBFUSCATED_VALUE", "VALUE_CHANGED", "SCAN_STATUS", "SCANNED_AT", "RUN_ID", "RAW_API_RESPONSE"}
    if required_output - output_columns:
        raise ValueError("OUTPUT_TABLE does not have the required connector result schema")
    return c, source, output, key, scanned


def _write_error(session, run_id, record_id, batch_id, stage, message, status=None, body=None, store_body=False):
    batch = "NULL" if batch_id is None else "?"
    http_status = "NULL" if status is None else "?"
    body_sql = "NULL" if not store_body else "PARSE_JSON(?)"
    params = [run_id, record_id]
    if batch_id is not None: params.append(batch_id)
    params.append(stage)
    if status is not None: params.append(status)
    params.append(message[:2000])
    if store_body: params.append(_json(body))
    _execute(session, f"""
      INSERT INTO NULLAFI_CONNECTOR_ERROR_LOG
        (ERROR_ID, RUN_ID, SOURCE_RECORD_ID, BATCH_ID, ERROR_STAGE, HTTP_STATUS_CODE, ERROR_MESSAGE, RESPONSE_BODY)
      SELECT UUID_STRING(), ?, ?, {batch}, ?, {http_status}, ?, {body_sql}
    """, params)


def _merge_result(session, output, config_name, run_id, record_id, column, value, changed, status, body, store_body):
    changed_sql = "NULL" if changed is None else "?"
    raw_sql = "NULL" if not store_body else "PARSE_JSON(?)"
    params = [config_name, record_id, column, value]
    if changed is not None: params.append(changed)
    params.extend([status, run_id])
    if store_body: params.append(_json(body))
    insert_params = [config_name, record_id, column, value]
    if changed is not None: insert_params.append(changed)
    insert_params.extend([status, run_id])
    if store_body: insert_params.append(_json(body))
    _execute(session, f"""
      MERGE INTO {output} AS target
      USING (SELECT ? AS CONFIG_NAME, ? AS SOURCE_RECORD_ID, ? AS SCAN_COLUMN) AS source
      ON target.CONFIG_NAME = source.CONFIG_NAME AND target.SOURCE_RECORD_ID = source.SOURCE_RECORD_ID
         AND target.SCAN_COLUMN = source.SCAN_COLUMN
      WHEN MATCHED THEN UPDATE SET OBFUSCATED_VALUE=?, VALUE_CHANGED={changed_sql}, SCAN_STATUS=?,
        SCANNED_AT=CURRENT_TIMESTAMP(), RUN_ID=?, RAW_API_RESPONSE={raw_sql}
      WHEN NOT MATCHED THEN INSERT (CONFIG_NAME, SOURCE_RECORD_ID, SCAN_COLUMN, OBFUSCATED_VALUE,
        VALUE_CHANGED, SCAN_STATUS, SCANNED_AT, RUN_ID, RAW_API_RESPONSE)
      VALUES (?, ?, ?, ?, {changed_sql}, ?, CURRENT_TIMESTAMP(), ?, {raw_sql})
    """, params + insert_params)


def _batches(items, limit):
    result, current = [], []
    for record_items in items:
        if current and len(current) + len(record_items) > limit:
            result.append(current); current = []
        current.extend(record_items)
    return result + ([current] if current else [])


def run(session, config_name, max_rows, retry_failed):
    if max_rows is None or not 1 <= int(max_rows) <= 10000:
        raise ValueError("MAX_ROWS must be between 1 and 10000")
    config, source, output, key, scanned = _load_config(session, config_name)
    run_id, max_rows = str(uuid.uuid4()), int(max_rows)
    metrics = {"rows_selected": 0, "rows_processed": 0, "rows_failed": 0, "output_rows_written": 0, "api_calls": 0, "api_call_failures": 0}
    _execute(session, "INSERT INTO NULLAFI_CONNECTOR_RUN_LOG (RUN_ID, RUN_STATUS) VALUES (?, 'RUNNING')", [run_id])
    try:
        # MERGE is the deliberate stream-consumption boundary. It commits an
        # ID-only work item before the external request begins.
        _execute(session, f"""
          MERGE INTO NULLAFI_CONNECTOR_WORK_QUEUE AS target
          USING (SELECT METADATA$ROW_ID AS STREAM_ROW_ID, {key}::STRING AS SOURCE_RECORD_ID
                 FROM NULLAFI_CONNECTOR_INPUT_STREAM
                 WHERE METADATA$ACTION='INSERT' AND METADATA$ISUPDATE=FALSE) AS source
          ON target.STREAM_ROW_ID=source.STREAM_ROW_ID
          WHEN NOT MATCHED THEN INSERT (STREAM_ROW_ID, SOURCE_RECORD_ID) VALUES (source.STREAM_ROW_ID, source.SOURCE_RECORD_ID)
        """)
        statuses = "'PENDING', 'FAILED'" if retry_failed else "'PENDING'"
        _execute(session, f"""
          UPDATE NULLAFI_CONNECTOR_WORK_QUEUE AS q SET QUEUE_STATUS='SKIPPED_SOURCE_DELETED',
            LAST_ATTEMPT_AT=CURRENT_TIMESTAMP(), LAST_ERROR_MESSAGE='Source record was deleted before scanning; no API request was made.'
          WHERE q.QUEUE_STATUS IN ({statuses}) AND NOT EXISTS
            (SELECT 1 FROM {source} AS s WHERE s.{key}::STRING=q.SOURCE_RECORD_ID)
        """)
        fields = ", ".join(f"s.{column} AS C{index}" for index, column in enumerate(scanned))
        records = session.sql(f"""
          SELECT q.STREAM_ROW_ID, q.SOURCE_RECORD_ID, {fields}
          FROM NULLAFI_CONNECTOR_WORK_QUEUE AS q JOIN {source} AS s ON s.{key}::STRING=q.SOURCE_RECORD_ID
          WHERE q.QUEUE_STATUS IN ({statuses}) ORDER BY q.QUEUED_AT, q.STREAM_ROW_ID LIMIT {max_rows}
        """).collect()
        metrics["rows_selected"] = len(records)
        errors, groups, payload_number = {}, [], 0
        for record in records:
            record_id, items = record["SOURCE_RECORD_ID"], []
            errors[record_id] = []
            for index, column in enumerate(scanned):
                value = record[f"C{index}"]
                display_column = column.replace('"', '')
                if value is None:
                    _merge_result(session, output, config_name, run_id, record_id, display_column, None, None, "SKIPPED_NULL", {"skipped": "null input"}, config["STORE_RAW_RESPONSES"])
                    metrics["output_rows_written"] += 1; continue
                text = str(value)
                if len(text) > int(config["MAX_FIELD_CHARACTERS"]):
                    message = f"{display_column} exceeds configured field limit; it was not sent to Nullafi."
                    errors[record_id].append(message)
                    _write_error(session, run_id, record_id, None, "FIELD_VALIDATION", message, store_body=config["STORE_RAW_RESPONSES"])
                    continue
                payload_number += 1
                items.append({"payload_key": f"v_{payload_number}", "record_id": record_id, "column": display_column, "value": text})
            if items: groups.append(items)
        endpoint = config["BASE_URL"].rstrip("/") + "/" + config["SCAN_PATH"].lstrip("/")
        api_key = _snowflake.get_generic_secret_string("nullafi_api_key")
        for batch_id, batch in enumerate(_batches(groups, int(config["MAX_VALUES_PER_REQUEST"])), 1):
            response = body = None; metrics["api_calls"] += 1
            try:
                response = HTTP_SESSION.post(endpoint, params={"namespace": config["NULLAFI_NAMESPACE"]}, headers={"Authorization": "Bearer " + api_key, "Content-Type": "application/json", "Accept": "application/json"}, json={item["payload_key"]: item["value"] for item in batch}, timeout=20)
                try: body = response.json()
                except ValueError: body = {"non_json_response": response.text[:500]}
                if not 200 <= response.status_code < 300: raise RuntimeError(f"Nullafi returned HTTP {response.status_code}")
                if not isinstance(body, dict): raise RuntimeError("Nullafi returned a successful non-object JSON response")
            except (requests.RequestException, RuntimeError) as exc:
                metrics["api_call_failures"] += 1
                for record_id in {item["record_id"] for item in batch}:
                    errors[record_id].append(str(exc))
                    _write_error(session, run_id, record_id, batch_id, "NULLAFI_BATCH", str(exc), getattr(response, "status_code", None), body, config["STORE_RAW_RESPONSES"])
                continue
            for item in batch:
                if item["payload_key"] not in body:
                    message = f"Nullafi response omitted payload key {item['payload_key']}"
                    errors[item["record_id"]].append(message)
                    _write_error(session, run_id, item["record_id"], batch_id, "RESPONSE_VALIDATION", message, response.status_code, body, config["STORE_RAW_RESPONSES"]); continue
                returned = body[item["payload_key"]]
                returned_text = None if returned is None else str(returned)
                changed = returned_text != item["value"]
                _merge_result(session, output, config_name, run_id, item["record_id"], item["column"], returned_text, changed, "SUCCESS" if changed else "NO_MATCH", body, config["STORE_RAW_RESPONSES"])
                metrics["output_rows_written"] += 1
        for record in records:
            record_id = record["SOURCE_RECORD_ID"]
            message = "; ".join(errors[record_id])[:2000] if errors[record_id] else None
            status = "FAILED" if message else "PROCESSED"
            metrics["rows_failed" if message else "rows_processed"] += 1
            _execute(session, f"UPDATE NULLAFI_CONNECTOR_WORK_QUEUE SET QUEUE_STATUS=?, LAST_ATTEMPT_AT=CURRENT_TIMESTAMP(), LAST_ERROR_MESSAGE={'?' if message else 'NULL'} WHERE STREAM_ROW_ID=?", [status] + ([message] if message else []) + [record["STREAM_ROW_ID"]])
        _execute(session, """UPDATE NULLAFI_CONNECTOR_RUN_LOG SET FINISHED_AT=CURRENT_TIMESTAMP(), RUN_STATUS='SUCCESS', ROWS_SELECTED=?, ROWS_PROCESSED=?, ROWS_FAILED=?, OUTPUT_ROWS_WRITTEN=?, API_CALLS=?, API_CALL_FAILURES=?, DURATION_MS=DATEDIFF('millisecond', STARTED_AT, CURRENT_TIMESTAMP()) WHERE RUN_ID=?""", [*metrics.values(), run_id])
        return {"run_id": run_id, "status": "SUCCESS", **metrics}
    except Exception as exc:
        _execute(session, "UPDATE NULLAFI_CONNECTOR_RUN_LOG SET FINISHED_AT=CURRENT_TIMESTAMP(), RUN_STATUS='FAILED', FAILURE_MESSAGE=? WHERE RUN_ID=?", [str(exc)[:2000], run_id])
        raise
$$;

-- Fail fast here: a typo in the table or mapping should stop installation,
-- rather than appearing as a mysterious scheduled-task failure later.
CALL NULLAFI_CONNECTOR_VALIDATE_CONFIG();

ALTER TASK IF EXISTS NULLAFI_CONNECTOR_PROCESS_TASK SUSPEND;
CREATE OR REPLACE TASK NULLAFI_CONNECTOR_PROCESS_TASK
  -- CREATE TASK defines WAREHOUSE as a string property, so use the session
  -- variable directly here (IDENTIFIER() is for object-name positions).
  WAREHOUSE = $NULLAFI_TASK_WAREHOUSE
  SCHEDULE = $NULLAFI_TASK_SCHEDULE
  USER_TASK_TIMEOUT_MS = 300000
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Runs the configured insert-only Nullafi connector.'
AS CALL NULLAFI_CONNECTOR_PROCESS();

ALTER TASK IF EXISTS NULLAFI_CONNECTOR_MONITOR_TASK SUSPEND;
CREATE OR REPLACE TASK NULLAFI_CONNECTOR_MONITOR_TASK
  WAREHOUSE = $NULLAFI_TASK_WAREHOUSE
  SCHEDULE = $NULLAFI_TASK_SCHEDULE
  USER_TASK_TIMEOUT_MS = 300000
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Persists task-level failures independently of the processing task.'
AS
  MERGE INTO NULLAFI_CONNECTOR_TASK_FAILURE_LOG AS target
  USING (
    SELECT QUERY_ID AS TASK_QUERY_ID, NAME AS TASK_NAME, STATE AS TASK_STATE,
           SCHEDULED_TIME AS SCHEDULED_AT, COMPLETED_TIME AS COMPLETED_AT,
           ERROR_CODE::STRING AS ERROR_CODE, ERROR_MESSAGE
    FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
      SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
      SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(), RESULT_LIMIT => 1000,
      TASK_NAME => 'NULLAFI_CONNECTOR_PROCESS_TASK', ERROR_ONLY => TRUE
    )) WHERE QUERY_ID IS NOT NULL
  ) AS source ON target.TASK_QUERY_ID=source.TASK_QUERY_ID
  WHEN NOT MATCHED THEN INSERT (TASK_QUERY_ID, TASK_NAME, TASK_STATE, SCHEDULED_AT, COMPLETED_AT, ERROR_CODE, ERROR_MESSAGE)
  VALUES (source.TASK_QUERY_ID, source.TASK_NAME, source.TASK_STATE, source.SCHEDULED_AT, source.COMPLETED_AT, source.ERROR_CODE, source.ERROR_MESSAGE);

CREATE OR REPLACE VIEW NULLAFI_CONNECTOR_PIPELINE_ALERTS AS
SELECT * FROM NULLAFI_CONNECTOR_RUN_LOG
WHERE RUN_STATUS='FAILED' OR ROWS_FAILED>0 OR API_CALL_FAILURES>0;

-- The installer validates and creates objects, but leaves tasks suspended.
-- This prevents an accidental production scan while the user reviews config.
-- After reviewing SELECT * FROM NULLAFI_CONNECTOR_CONFIG, enable automation:
-- ALTER TASK NULLAFI_CONNECTOR_PROCESS_TASK RESUME;
-- ALTER TASK NULLAFI_CONNECTOR_MONITOR_TASK RESUME;
-- For a first controlled run without scheduling: CALL NULLAFI_CONNECTOR_PROCESS();
