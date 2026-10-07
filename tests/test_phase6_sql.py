"""Static and local-Python checks for the reusable Phase 6 installer.

These checks intentionally do not require a Snowflake account. A fresh-schema
run is tracked separately in PLAN.md because it needs a real account, role,
warehouse, and Nullafi key.
"""

import sys
import types
import re
from pathlib import Path


SQL_PATH = Path("snowflake/phase6_setup.sql")


def read_sql() -> str:
    return SQL_PATH.read_text(encoding="utf-8")


def load_processor(monkeypatch):
    sql = read_sql()
    marker = "CREATE OR REPLACE PROCEDURE NULLAFI_CONNECTOR_PROCESS"
    start = sql.index("AS\n$$\n", sql.index(marker)) + len("AS\n$$\n")
    end = sql.index("\n$$;", start)
    secret_module = types.ModuleType("_snowflake")
    secret_module.get_generic_secret_string = lambda alias: "test-key"
    monkeypatch.setitem(sys.modules, "_snowflake", secret_module)
    namespace = {"__name__": "phase6_handler_test"}
    exec(compile(sql[start:end], str(SQL_PATH), "exec"), namespace)
    return namespace


def load_validator():
    sql = read_sql()
    marker = "CREATE OR REPLACE PROCEDURE NULLAFI_CONNECTOR_VALIDATE_CONFIG"
    start = sql.index("AS\n$$\n", sql.index(marker)) + len("AS\n$$\n")
    end = sql.index("\n$$;", start)
    namespace = {"__name__": "phase6_validator_test"}
    exec(compile(sql[start:end], str(SQL_PATH), "exec"), namespace)
    return namespace


def test_installer_provisions_configured_connector_objects() -> None:
    sql = read_sql()

    assert "SET NULLAFI_SOURCE_TABLE" in sql
    assert "SET NULLAFI_SCAN_COLUMNS" in sql
    assert "CREATE OR REPLACE TABLE NULLAFI_CONNECTOR_CONFIG" in sql
    assert "CREATE OR REPLACE STREAM NULLAFI_CONNECTOR_INPUT_STREAM" in sql
    assert "CREATE OR REPLACE PROCEDURE NULLAFI_CONNECTOR_VALIDATE_CONFIG" in sql
    assert "CREATE OR REPLACE PROCEDURE NULLAFI_CONNECTOR_PROCESS" in sql
    assert "CREATE OR REPLACE TASK NULLAFI_CONNECTOR_PROCESS_TASK" in sql
    assert "CREATE OR REPLACE TASK NULLAFI_CONNECTOR_MONITOR_TASK" in sql


def test_installer_keeps_tasks_suspended_until_user_enables_them() -> None:
    sql = read_sql()

    assert "ALTER TASK IF EXISTS NULLAFI_CONNECTOR_PROCESS_TASK SUSPEND" in sql
    assert "ALTER TASK IF EXISTS NULLAFI_CONNECTOR_MONITOR_TASK SUSPEND" in sql
    assert not re.search(r"(?m)^ALTER TASK NULLAFI_CONNECTOR_PROCESS_TASK RESUME;", sql)
    assert not re.search(r"(?m)^ALTER TASK NULLAFI_CONNECTOR_MONITOR_TASK RESUME;", sql)


def test_processor_safely_normalizes_configured_identifiers(monkeypatch) -> None:
    handler = load_processor(monkeypatch)

    assert handler["_name"]("app_db.raw.customers", "SOURCE_TABLE") == (
        '"APP_DB"."RAW"."CUSTOMERS"'
    )
    assert handler["_name"]("email", "SCAN_COLUMNS entry", (1,)) == '"EMAIL"'
    for unsafe in ("a; DROP TABLE x", "a.b.c.d", '"MixedCase"'):
        try:
            handler["_name"](unsafe, "SOURCE_TABLE")
        except ValueError:
            pass
        else:
            raise AssertionError(f"unsafe identifier {unsafe!r} was accepted")


def test_handlers_accept_snowflake_array_json_text_and_native_lists(monkeypatch) -> None:
    validator = load_validator()
    processor = load_processor(monkeypatch)

    expected = ["EMAIL", "SSN", "NOTES"]
    assert validator["scan_columns_as_list"]('["EMAIL", "SSN", "NOTES"]') == expected
    assert processor["_scan_columns_as_list"]('["EMAIL", "SSN", "NOTES"]') == expected
    assert validator["scan_columns_as_list"](expected) == expected
    assert processor["_scan_columns_as_list"](expected) == expected


def test_processor_uses_bound_secret_and_gates_raw_response_storage() -> None:
    sql = read_sql()

    assert "SECRETS = ('nullafi_api_key' = NULLAFI_CONNECTOR_API_KEY)" in sql
    assert '_snowflake.get_generic_secret_string("nullafi_api_key")' in sql
    assert "STORE_RAW_RESPONSES BOOLEAN NOT NULL DEFAULT FALSE" in sql
    assert "RAW_API_RESPONSE is NULL unless explicitly enabled" in sql
