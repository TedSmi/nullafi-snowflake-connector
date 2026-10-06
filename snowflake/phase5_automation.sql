-- Phase 5: schedule the Phase 4 stream consumer and persist task-level
-- failures for monitoring.
--
-- Prerequisite: run snowflake/phase2_connectivity.sql and the complete
-- snowflake/phase3_batch_pipeline.sql script in this schema first.
--
-- Run this script as the role that owns NULLAFI_PROCESS_BATCH and has USAGE on
-- the warehouse. The role also needs CREATE TASK in this schema and sufficient
-- access to query this schema's TASK_HISTORY. Replace <YOUR_WAREHOUSE> below
-- with an existing, dedicated or appropriately sized warehouse identifier.
--
-- The processing task runs every five minutes. It intentionally runs on a
-- schedule rather than only when SYSTEM$STREAM_HAS_DATA is true: queued failed
-- rows may need an explicit retry even after the stream offset has advanced.

-- Set the worksheet context before running this script.
-- USE ROLE <ROLE_THAT_OWNS_THE_PROCEDURE>;
-- USE WAREHOUSE <YOUR_WAREHOUSE>;
-- USE DATABASE <YOUR_DATABASE>;
-- USE SCHEMA <YOUR_SCHEMA>;

CREATE TABLE IF NOT EXISTS NULLAFI_PHASE5_TASK_FAILURE_LOG (
  TASK_QUERY_ID STRING NOT NULL,
  TASK_NAME STRING NOT NULL,
  TASK_STATE STRING NOT NULL,
  SCHEDULED_AT TIMESTAMP_LTZ,
  COMPLETED_AT TIMESTAMP_LTZ,
  ERROR_CODE STRING,
  ERROR_MESSAGE STRING,
  RECORDED_AT TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT NULLAFI_PHASE5_TASK_FAILURE_LOG_PK PRIMARY KEY (TASK_QUERY_ID)
)
COMMENT = 'Task-level failures copied from TASK_HISTORY; query this table for actionable automation failures.';

-- Replace an existing task safely. CREATE OR REPLACE creates the replacement
-- task in a suspended state; the explicit RESUME at the end enables scheduling.
ALTER TASK IF EXISTS NULLAFI_PHASE5_PROCESS_TASK SUSPEND;

CREATE OR REPLACE TASK NULLAFI_PHASE5_PROCESS_TASK
  WAREHOUSE = <YOUR_WAREHOUSE>
  SCHEDULE = '5 MINUTES'
  USER_TASK_TIMEOUT_MS = 300000
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Runs the stream-backed Nullafi batch procedure every five minutes.'
AS
  CALL NULLAFI_PROCESS_BATCH();

-- This independent task persists pipeline-task failures. It is not a child in
-- a task graph because child tasks do not run after a failed predecessor.
ALTER TASK IF EXISTS NULLAFI_PHASE5_MONITOR_TASK SUSPEND;

CREATE OR REPLACE TASK NULLAFI_PHASE5_MONITOR_TASK
  WAREHOUSE = <YOUR_WAREHOUSE>
  SCHEDULE = '5 MINUTES'
  USER_TASK_TIMEOUT_MS = 300000
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
  COMMENT = 'Copies failed Phase 5 processing-task executions into the failure log.'
AS
  MERGE INTO NULLAFI_PHASE5_TASK_FAILURE_LOG AS target
  USING (
    SELECT
      QUERY_ID AS TASK_QUERY_ID,
      NAME AS TASK_NAME,
      STATE AS TASK_STATE,
      SCHEDULED_TIME AS SCHEDULED_AT,
      COMPLETED_TIME AS COMPLETED_AT,
      ERROR_CODE::STRING AS ERROR_CODE,
      ERROR_MESSAGE
    FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
      SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
      SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(),
      RESULT_LIMIT => 1000,
      TASK_NAME => 'NULLAFI_PHASE5_PROCESS_TASK',
      ERROR_ONLY => TRUE
    ))
    WHERE QUERY_ID IS NOT NULL
  ) AS source
    ON target.TASK_QUERY_ID = source.TASK_QUERY_ID
  WHEN NOT MATCHED THEN INSERT (
    TASK_QUERY_ID, TASK_NAME, TASK_STATE, SCHEDULED_AT, COMPLETED_AT,
    ERROR_CODE, ERROR_MESSAGE
  ) VALUES (
    source.TASK_QUERY_ID, source.TASK_NAME, source.TASK_STATE,
    source.SCHEDULED_AT, source.COMPLETED_AT, source.ERROR_CODE,
    source.ERROR_MESSAGE
  );

-- Recoverable service and row failures do not fail the task: the batch
-- procedure records them and continues. This view is the monitoring surface
-- for those degraded-but-completed runs; the failure table above is for task
-- executions that fail before or outside that controlled error path.
CREATE OR REPLACE VIEW NULLAFI_PHASE5_PIPELINE_ALERTS AS
SELECT
  RUN_ID,
  STARTED_AT,
  FINISHED_AT,
  RUN_STATUS,
  ROWS_SELECTED,
  ROWS_PROCESSED,
  ROWS_FAILED,
  API_CALLS,
  API_CALL_FAILURES,
  FAILURE_MESSAGE
FROM NULLAFI_PHASE3_RUN_LOG
WHERE RUN_STATUS = 'FAILED'
   OR ROWS_FAILED > 0
   OR API_CALL_FAILURES > 0;

-- Tasks are created suspended. Resume both only after reviewing their
-- definitions and confirming the chosen warehouse is appropriate.
ALTER TASK NULLAFI_PHASE5_PROCESS_TASK RESUME;
ALTER TASK NULLAFI_PHASE5_MONITOR_TASK RESUME;

-- ---------------------------------------------------------------------------
-- Operations and validation
-- ---------------------------------------------------------------------------
-- Pause automation before making task-definition changes or maintenance work:
-- ALTER TASK NULLAFI_PHASE5_PROCESS_TASK SUSPEND;
-- ALTER TASK NULLAFI_PHASE5_MONITOR_TASK SUSPEND;
--
-- Resume it after maintenance:
-- ALTER TASK NULLAFI_PHASE5_PROCESS_TASK RESUME;
-- ALTER TASK NULLAFI_PHASE5_MONITOR_TASK RESUME;
--
-- Run the pipeline task once without waiting for its five-minute schedule:
-- EXECUTE TASK NULLAFI_PHASE5_PROCESS_TASK;
--
-- Check recent task executions (use SQL rather than relying on the UI):
-- SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, QUERY_ID,
--        ERROR_CODE, ERROR_MESSAGE
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--   SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
--   SCHEDULED_TIME_RANGE_END => CURRENT_TIMESTAMP(),
--   RESULT_LIMIT => 100,
--   TASK_NAME => 'NULLAFI_PHASE5_PROCESS_TASK'
-- ))
-- WHERE QUERY_ID IS NOT NULL
-- ORDER BY SCHEDULED_TIME DESC;
--
-- Check both task-level and recoverable pipeline failures:
-- SELECT * FROM NULLAFI_PHASE5_TASK_FAILURE_LOG
-- ORDER BY RECORDED_AT DESC;
-- SELECT * FROM NULLAFI_PHASE5_PIPELINE_ALERTS
-- ORDER BY STARTED_AT DESC;
--
-- Normal-operation test (run after the task is resumed). Insert a new synthetic
-- row, then either wait for the next schedule or execute the processing task.
-- Its run-log row should show one selected/processed record.
-- INSERT INTO NULLAFI_PHASE3_SAMPLE_INPUT (
--   RECORD_ID, EMAIL, SSN, CREDIT_CARD, FULL_NAME, NOTES
-- ) VALUES (
--   'cust_005', 'automated.customer@example.net', '321-54-9876',
--   '4000000000000002', 'Automated Customer',
--   'Synthetic Phase 5 task-validation row.'
-- );
-- EXECUTE TASK NULLAFI_PHASE5_PROCESS_TASK;
--
-- Task-failure monitoring test. This safely forces argument validation to fail
-- before any API request; it does not modify the secret. Suspend the task,
-- replace its statement temporarily, execute it once, then execute the monitor
-- task and inspect NULLAFI_PHASE5_TASK_FAILURE_LOG. Re-run this file afterward
-- to restore the normal definition and resume both tasks.
-- ALTER TASK NULLAFI_PHASE5_PROCESS_TASK SUSPEND;
-- ALTER TASK NULLAFI_PHASE5_PROCESS_TASK MODIFY AS CALL NULLAFI_PROCESS_BATCH(0);
-- EXECUTE TASK NULLAFI_PHASE5_PROCESS_TASK;
-- EXECUTE TASK NULLAFI_PHASE5_MONITOR_TASK;
-- SELECT * FROM NULLAFI_PHASE5_TASK_FAILURE_LOG
-- ORDER BY RECORDED_AT DESC;
