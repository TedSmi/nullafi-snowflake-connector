from pathlib import Path


SQL_PATH = Path("snowflake/phase3_batch_pipeline.sql")


def read_sql() -> str:
    return SQL_PATH.read_text(encoding="utf-8")


def test_phase3_sql_creates_pipeline_tables_and_procedure() -> None:
    sql = read_sql()

    assert "CREATE OR REPLACE TABLE NULLAFI_PHASE3_SAMPLE_INPUT" in sql
    assert "CREATE OR REPLACE TABLE NULLAFI_PHASE3_SCAN_OUTPUT" in sql
    assert "CREATE OR REPLACE TABLE NULLAFI_PHASE3_ERROR_LOG" in sql
    assert "CREATE OR REPLACE TABLE NULLAFI_PHASE3_RUN_LOG" in sql
    assert "CREATE OR REPLACE PROCEDURE NULLAFI_PROCESS_BATCH" in sql


def test_phase3_sql_batches_values_and_caps_field_size() -> None:
    sql = read_sql()

    assert "MAX_FIELD_CHARACTERS = 1000" in sql
    assert "MAX_VALUES_PER_REQUEST = 20" in sql
    assert "def _chunks_by_record(items_by_record):" in sql
    assert "payload = {item[\"payload_key\"]: item[\"value\"] for item in batch_items}" in sql


def test_phase3_sql_has_recoverable_errors_and_idempotent_writes() -> None:
    sql = read_sql()

    assert "MERGE INTO NULLAFI_PHASE3_SCAN_OUTPUT" in sql
    assert "PROCESSING_STATUS = 'FAILED'" in sql
    assert "PROCESSING_STATUS = 'PROCESSED'" in sql
    assert "INSERT INTO NULLAFI_PHASE3_ERROR_LOG" in sql
    assert "RETRY_FAILED BOOLEAN DEFAULT FALSE" in sql
    assert "NULLAFI_PHASE3_RUN_LOG" in sql
    assert "DURATION_MS" in sql


def test_phase3_sql_uses_snowflake_secret_alias_without_literal_key() -> None:
    sql = read_sql()

    assert "SECRETS = ('nullafi_api_key' = NULLAFI_API_KEY)" in sql
    assert '_snowflake.get_generic_secret_string("nullafi_api_key")' in sql
    assert '"Authorization": "Bearer " + api_key' in sql
    assert "<PASTE_NULLAFI_API_KEY_HERE>" not in sql
    assert "nul_" not in sql.lower()
