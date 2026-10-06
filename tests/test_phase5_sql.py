from pathlib import Path


SQL_PATH = Path("snowflake/phase5_automation.sql")


def read_sql() -> str:
    return SQL_PATH.read_text(encoding="utf-8")


def test_phase5_creates_scheduled_processing_and_monitor_tasks() -> None:
    sql = read_sql()

    assert "CREATE OR REPLACE TASK NULLAFI_PHASE5_PROCESS_TASK" in sql
    assert "CREATE OR REPLACE TASK NULLAFI_PHASE5_MONITOR_TASK" in sql
    assert "WAREHOUSE = <YOUR_WAREHOUSE>" in sql
    assert "SCHEDULE = '5 MINUTES'" in sql
    assert "CALL NULLAFI_PROCESS_BATCH();" in sql
    assert "SUSPEND_TASK_AFTER_NUM_FAILURES = 3" in sql
    assert "ALTER TASK NULLAFI_PHASE5_PROCESS_TASK RESUME" in sql
    assert "ALTER TASK NULLAFI_PHASE5_MONITOR_TASK RESUME" in sql


def test_phase5_persists_task_failures_and_exposes_recoverable_failures() -> None:
    sql = read_sql()

    assert "CREATE TABLE IF NOT EXISTS NULLAFI_PHASE5_TASK_FAILURE_LOG" in sql
    assert "INFORMATION_SCHEMA.TASK_HISTORY(" in sql
    assert "ERROR_ONLY => TRUE" in sql
    assert "MERGE INTO NULLAFI_PHASE5_TASK_FAILURE_LOG" in sql
    assert "CREATE OR REPLACE VIEW NULLAFI_PHASE5_PIPELINE_ALERTS" in sql
    assert "ROWS_FAILED > 0" in sql
    assert "API_CALL_FAILURES > 0" in sql


def test_phase5_documents_manual_execution_and_safe_failure_validation() -> None:
    sql = read_sql()

    assert "EXECUTE TASK NULLAFI_PHASE5_PROCESS_TASK;" in sql
    assert "MODIFY AS CALL NULLAFI_PROCESS_BATCH(0);" in sql
    assert "does not modify the secret" in sql
