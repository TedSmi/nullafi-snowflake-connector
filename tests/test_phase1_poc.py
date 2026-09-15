from pathlib import Path

import pytest

from src.phase1_poc import (
    FakeRecord,
    build_scan_payload,
    parse_scan_response,
    read_fake_data,
    verify_expected_sensitive_fields,
)


def test_read_fake_data_loads_records() -> None:
    records = read_fake_data(Path("data/fake_sensitive_data.json"))

    assert len(records) == 3
    assert records[0].record_id == "cust_001"
    assert "ssn" in records[0].expected_sensitive_fields


def test_build_scan_payload_skips_nulls_and_casts_values() -> None:
    record = FakeRecord(
        record_id="row_1",
        scan_fields={"present": 123, "missing": None},
        expected_sensitive_fields=[],
        field_notes={},
    )

    assert build_scan_payload(record) == {"present": "123"}


def test_parse_scan_response_marks_changed_values() -> None:
    record = FakeRecord(
        record_id="row_1",
        scan_fields={"ssn": "122-12-8348", "notes": None},
        expected_sensitive_fields=["ssn"],
        field_notes={},
    )
    payload = build_scan_payload(record)

    parsed = parse_scan_response(record, payload, {"ssn": "***-**-8348"})

    assert parsed["record_id"] == "row_1"
    assert parsed["skipped_null_fields"] == ["notes"]
    assert parsed["field_results"][0]["changed"] is True
    assert parsed["field_results"][0]["expected_sensitive"] is True


def test_verify_expected_sensitive_fields_fails_when_sensitive_value_unchanged() -> None:
    results = [
        {
            "record_id": "row_1",
            "field_results": [
                {
                    "field_name": "ssn",
                    "expected_sensitive": True,
                    "changed": False,
                }
            ],
        }
    ]

    with pytest.raises(AssertionError, match="row_1.ssn"):
        verify_expected_sensitive_fields(results, allow_unchanged_expected=False)


def test_verify_expected_sensitive_fields_can_warn_instead_of_fail() -> None:
    results = [
        {
            "record_id": "row_1",
            "field_results": [
                {
                    "field_name": "ssn",
                    "expected_sensitive": True,
                    "changed": False,
                }
            ],
        }
    ]

    verify_expected_sensitive_fields(results, allow_unchanged_expected=True)
