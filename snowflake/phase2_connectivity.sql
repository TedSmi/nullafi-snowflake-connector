-- Phase 2: Snowflake -> Nullafi connectivity proof.
--
-- Run this in a Snowflake worksheet after choosing the target database/schema.
-- Replace only the placeholder values that are marked with angle brackets.
-- Never commit a real Nullafi key back into this repository.

-- ---------------------------------------------------------------------------
-- 1. Context
-- ---------------------------------------------------------------------------
-- USE ROLE ACCOUNTADMIN;
-- USE WAREHOUSE <YOUR_WAREHOUSE>;
-- USE DATABASE <YOUR_DATABASE>;
-- USE SCHEMA <YOUR_SCHEMA>;

-- ---------------------------------------------------------------------------
-- 2. External network access objects
-- ---------------------------------------------------------------------------
-- Network rules are schema-level objects. External access integrations are
-- account-level objects that reference one or more network rules and secrets.
CREATE OR REPLACE NETWORK RULE NULLAFI_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('openflow.nullafi.net')
  COMMENT = 'Allow outbound HTTPS from Snowflake Python procedures to Nullafi.';

-- Use a generic-string secret for the Nullafi bearer token. Snowflake exposes
-- this to Python handler code through the secret alias configured below; the
-- procedure never receives or returns the plaintext key.
CREATE OR REPLACE SECRET NULLAFI_API_KEY
  TYPE = GENERIC_STRING
  SECRET_STRING = '<PASTE_NULLAFI_API_KEY_HERE>'
  COMMENT = 'Nullafi API key for the Snowflake connector proof of connectivity.';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION NULLAFI_EXTERNAL_ACCESS_INTEGRATION
  ALLOWED_NETWORK_RULES = (NULLAFI_API_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (NULLAFI_API_KEY)
  ENABLED = TRUE
  COMMENT = 'Allows approved Python procedures to call the Nullafi API.';

-- ---------------------------------------------------------------------------
-- 3. Minimal stored procedure
-- ---------------------------------------------------------------------------
-- This procedure proves the whole chain works:
-- Snowflake procedure -> External Access Integration -> Secret -> Nullafi.
CREATE OR REPLACE PROCEDURE NULLAFI_PHASE2_CONNECTIVITY_TEST(
    NULLAFI_NAMESPACE STRING DEFAULT 'dlp test',
    TEST_VALUE STRING DEFAULT '122-12-8348',
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
import _snowflake
import requests

HTTP_SESSION = requests.Session()


def _join_url(base_url, scan_path):
    base = base_url.rstrip("/")
    path = scan_path if scan_path.startswith("/") else "/" + scan_path
    return base + path


def _response_body(response):
    try:
        return response.json()
    except ValueError:
        return {"non_json_response": response.text[:500]}


def run(session, nullafi_namespace, test_value, nullafi_base_url, nullafi_scan_path):
    api_key = _snowflake.get_generic_secret_string("nullafi_api_key")
    endpoint = _join_url(nullafi_base_url, nullafi_scan_path)
    payload = {"phase2_test_value": test_value}

    response = HTTP_SESSION.post(
        endpoint,
        params={"namespace": nullafi_namespace},
        headers={
            "Authorization": "Bearer " + api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        json=payload,
        timeout=15,
    )

    body = _response_body(response)
    returned_value = body.get("phase2_test_value") if isinstance(body, dict) else None

    return {
        "ok": 200 <= response.status_code < 300,
        "status_code": response.status_code,
        "request": {
            "base_url": nullafi_base_url,
            "scan_path": nullafi_scan_path,
            "namespace": nullafi_namespace,
            "payload_keys": list(payload.keys()),
        },
        "response_body": body,
        "changed": returned_value != test_value if returned_value is not None else None,
        "note": (
            "A 200 response proves Snowflake egress, secret access, and Nullafi auth. "
            "changed=false can still be expected until the Nullafi dashboard rule is attached."
        ),
    }
$$;

-- ---------------------------------------------------------------------------
-- 4. Smoke test
-- ---------------------------------------------------------------------------
CALL NULLAFI_PHASE2_CONNECTIVITY_TEST();

-- ---------------------------------------------------------------------------
-- 5. Secret exposure check
-- ---------------------------------------------------------------------------
-- After running the script, search recent query text for a fragment of the key.
-- Use only a short prefix/suffix that is enough to detect exposure. Do not paste
-- the full secret into ad hoc screenshots, docs, tickets, or shared logs.
--
-- SELECT query_id, start_time, user_name, role_name, query_text
-- FROM snowflake.account_usage.query_history
-- WHERE start_time >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
--   AND query_text ILIKE '%<SHORT_KEY_FRAGMENT>%'
-- ORDER BY start_time DESC;
