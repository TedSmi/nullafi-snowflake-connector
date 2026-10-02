"""Behavior tests for the Python handler embedded in the Phase 3 SQL file.

Snowflake runs this handler in its own runtime, so these tests extract it and
use small fakes for Snowpark, the Snowflake secret module, and Nullafi HTTP.
They exercise batching and recoverable failure behavior without a live account.
"""

import sys
import types
from pathlib import Path


SQL_PATH = Path("snowflake/phase3_batch_pipeline.sql")


def load_handler(monkeypatch):
    sql = SQL_PATH.read_text(encoding="utf-8")
    start = sql.index("AS\n$$\n") + len("AS\n$$\n")
    end = sql.index(
        "\n$$;\n\n-- ---------------------------------------------------------------------------\n"
        "-- 3. Validation queries",
        start,
    )
    snowflake_module = types.ModuleType("_snowflake")
    snowflake_module.get_generic_secret_string = lambda alias: "test-key"
    monkeypatch.setitem(sys.modules, "_snowflake", snowflake_module)

    namespace = {"__name__": "phase3_handler_test"}
    exec(compile(sql[start:end], str(SQL_PATH), "exec"), namespace)
    return namespace


class FakeQuery:
    def __init__(self, rows):
        self.rows = rows

    def collect(self):
        return self.rows


class FakeSnowparkSession:
    def __init__(self, records):
        self.records = records
        self.statements = []

    def sql(self, statement, params=None):
        self.statements.append((statement, params or []))
        if "FROM NULLAFI_PHASE3_SAMPLE_INPUT" in statement:
            return FakeQuery(self.records)
        return FakeQuery([])


class EchoResponse:
    status_code = 200

    def __init__(self, payload):
        self.payload = payload
        self.text = ""

    def json(self):
        return self.payload


class EchoHttpSession:
    def __init__(self):
        self.calls = []

    def post(self, endpoint, **kwargs):
        self.calls.append({"endpoint": endpoint, **kwargs})
        return EchoResponse(kwargs["json"])


class FailedResponse:
    status_code = 503
    text = '{"message":"temporarily unavailable"}'

    def json(self):
        return {"message": "temporarily unavailable"}


class FailedHttpSession:
    def post(self, *args, **kwargs):
        return FailedResponse()


def test_handler_batches_field_values_and_marks_successful_rows_processed(monkeypatch) -> None:
    handler = load_handler(monkeypatch)
    http = EchoHttpSession()
    handler["HTTP_SESSION"] = http
    records = [
        {
            "RECORD_ID": "cust_001",
            "EMAIL": "alex.test@example.com",
            "SSN": "122-12-8348",
            "CREDIT_CARD": "4111111111111111",
            "FULL_NAME": "Alex Example",
            "NOTES": "note one",
        },
        {
            "RECORD_ID": "cust_002",
            "EMAIL": "billing@example.org",
            "SSN": "078-05-1120",
            "CREDIT_CARD": "5555555555554444",
            "FULL_NAME": "Jordan Sample",
            "NOTES": None,
        },
    ]
    session = FakeSnowparkSession(records)

    result = handler["run"](
        session, 100, False, "dlp test", "https://api.example.test", "/scan"
    )

    assert result["status"] == "SUCCESS"
    assert result["rows_selected"] == 2
    assert result["rows_processed"] == 2
    assert result["rows_failed"] == 0
    assert result["api_calls"] == 1
    assert result["output_rows_written"] == 10
    assert len(http.calls) == 1
    assert len(http.calls[0]["json"]) == 9  # One of ten source values is null.
    assert all(key.startswith("v_") for key in http.calls[0]["json"])
    assert sum("MERGE INTO NULLAFI_PHASE3_SCAN_OUTPUT" in sql for sql, _ in session.statements) == 10
    # The null NOTES field must become SQL NULL, not the invalid BOOLEAN string
    # "None" that Snowpark can produce when it binds a Python None parameter.
    assert any("VALUE_CHANGED = NULL" in sql for sql, _ in session.statements)


def test_handler_dead_letters_failed_http_batch_without_raising(monkeypatch) -> None:
    handler = load_handler(monkeypatch)
    handler["HTTP_SESSION"] = FailedHttpSession()
    records = [
        {
            "RECORD_ID": "cust_failure",
            "EMAIL": "a@example.test",
            "SSN": "122-12-8348",
            "CREDIT_CARD": "4111111111111111",
            "FULL_NAME": "Failure Example",
            "NOTES": "normal field",
        }
    ]
    session = FakeSnowparkSession(records)

    result = handler["run"](
        session, 100, False, "dlp test", "https://api.example.test", "/scan"
    )

    assert result["status"] == "SUCCESS"
    assert result["rows_processed"] == 0
    assert result["rows_failed"] == 1
    assert result["api_calls"] == 1
    assert result["api_call_failures"] == 1
    assert any("INSERT INTO NULLAFI_PHASE3_ERROR_LOG" in sql for sql, _ in session.statements)
    assert any(
        "PROCESSING_STATUS = 'FAILED'" in sql for sql, _ in session.statements
    )


def test_handler_writes_sql_nulls_for_missing_error_metadata(monkeypatch) -> None:
    handler = load_handler(monkeypatch)
    session = FakeSnowparkSession([])

    # A local validation or transport failure has no batch ID and/or HTTP
    # status. Snowpark must receive SQL NULLs rather than stringified None.
    handler["_write_error"](
        session, "run_1", "record_1", None, "FIELD_VALIDATION", "too long"
    )

    statement, params = session.statements[-1]
    assert " ".join(statement.split()) == (
        "INSERT INTO NULLAFI_PHASE3_ERROR_LOG ( ERROR_ID, RUN_ID, SOURCE_RECORD_ID, "
        "BATCH_ID, ERROR_STAGE, HTTP_STATUS_CODE, ERROR_MESSAGE, RESPONSE_BODY ) "
        "SELECT UUID_STRING(), ?, ?, NULL, ?, NULL, ?, PARSE_JSON(?)"
    )
    assert None not in params
