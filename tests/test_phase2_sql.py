from pathlib import Path


SQL_PATH = Path("snowflake/phase2_connectivity.sql")


def read_sql() -> str:
    return SQL_PATH.read_text(encoding="utf-8")


def test_phase2_sql_defines_required_snowflake_objects() -> None:
    sql = read_sql()

    assert "CREATE OR REPLACE NETWORK RULE NULLAFI_API_NETWORK_RULE" in sql
    assert "CREATE OR REPLACE SECRET NULLAFI_API_KEY" in sql
    assert (
        "CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION "
        "NULLAFI_EXTERNAL_ACCESS_INTEGRATION"
    ) in sql
    assert "CREATE OR REPLACE PROCEDURE NULLAFI_PHASE2_CONNECTIVITY_TEST" in sql


def test_phase2_sql_keeps_real_api_key_out_of_repo() -> None:
    sql = read_sql()

    assert "<PASTE_NULLAFI_API_KEY_HERE>" in sql
    assert "nul_" not in sql.lower()


def test_phase2_procedure_uses_secret_alias_not_literal_key() -> None:
    sql = read_sql()

    assert "SECRETS = ('nullafi_api_key' = NULLAFI_API_KEY)" in sql
    assert '_snowflake.get_generic_secret_string("nullafi_api_key")' in sql
    assert '"Authorization": "Bearer " + api_key' in sql
