"""Run the Phase 1 local Nullafi proof of concept.

The script reads synthetic test records, sends non-empty values to Nullafi in a
single payload per record, then writes a normalized JSON result for inspection
and test assertions.
"""

from __future__ import annotations

from dataclasses import dataclass
import argparse
import json
import logging
from pathlib import Path
from typing import Any

try:
    from dotenv import load_dotenv
except ImportError:  # pragma: no cover - optional local convenience dependency
    load_dotenv = None

try:
    from .nullafi_client import NullafiAPIError, NullafiClient, NullafiConfig
except ImportError:  # pragma: no cover - supports `python src/phase1_poc.py`
    from nullafi_client import NullafiAPIError, NullafiClient, NullafiConfig


LOGGER = logging.getLogger("phase1_poc")
DEFAULT_DATA_PATH = Path("data/fake_sensitive_data.json")


@dataclass(frozen=True)
class FakeRecord:
    """One synthetic source row from the Phase 1 data file."""

    record_id: str
    scan_fields: dict[str, Any]
    expected_sensitive_fields: list[str]
    field_notes: dict[str, str]


def configure_logging(verbose: bool = False) -> None:
    level = logging.DEBUG if verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s - %(message)s",
    )


def read_fake_data(path: Path) -> list[FakeRecord]:
    """Load fake records and validate the small schema expected by the POC."""

    with path.open(encoding="utf-8") as data_file:
        raw_records = json.load(data_file)

    records: list[FakeRecord] = []
    for index, raw in enumerate(raw_records, start=1):
        try:
            records.append(
                FakeRecord(
                    record_id=str(raw["record_id"]),
                    scan_fields=dict(raw["scan_fields"]),
                    expected_sensitive_fields=list(raw["expected_sensitive_fields"]),
                    field_notes=dict(raw.get("field_notes", {})),
                )
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"Invalid fake data record at index {index}: {raw}") from exc

    return records


def build_scan_payload(record: FakeRecord) -> dict[str, str]:
    """Prepare one Nullafi payload, skipping nulls and casting values to strings."""

    payload: dict[str, str] = {}
    for field_name, value in record.scan_fields.items():
        if value is None:
            LOGGER.debug("Skipping null field '%s' on %s", field_name, record.record_id)
            continue
        payload[field_name] = str(value)
    return payload


def parse_scan_response(
    record: FakeRecord,
    payload: dict[str, str],
    response: dict[str, Any],
) -> dict[str, Any]:
    """Normalize Nullafi's response into fields useful for downstream pipeline design."""

    field_results = []
    for field_name, original_value in payload.items():
        returned_value = response.get(field_name)
        field_results.append(
            {
                "field_name": field_name,
                "original_value": original_value,
                "returned_value": returned_value,
                "changed": returned_value != original_value,
                "expected_sensitive": field_name in record.expected_sensitive_fields,
            }
        )

    skipped_null_fields = [
        field_name
        for field_name, value in record.scan_fields.items()
        if value is None
    ]

    return {
        "record_id": record.record_id,
        "field_results": field_results,
        "skipped_null_fields": skipped_null_fields,
        "raw_response": response,
    }


def verify_expected_sensitive_fields(
    parsed_results: list[dict[str, Any]],
    *,
    allow_unchanged_expected: bool,
) -> None:
    """Assert planted sensitive fields were changed unless explicitly allowed.

    During the first Nullafi dashboard pass, this assertion may reveal that the
    dashboard rule did not match the planted value. In that case, fix the
    dashboard/rule config or rerun with `--allow-unchanged-expected` while
    documenting the behavior in DESIGN.md.
    """

    unchanged_expected: list[str] = []
    for record_result in parsed_results:
        for field_result in record_result["field_results"]:
            if field_result["expected_sensitive"] and not field_result["changed"]:
                unchanged_expected.append(
                    f"{record_result['record_id']}.{field_result['field_name']}"
                )

    if unchanged_expected and not allow_unchanged_expected:
        joined = ", ".join(unchanged_expected)
        raise AssertionError(
            "Expected sensitive fields came back unchanged: "
            f"{joined}. Confirm the Nullafi dashboard rules match the fake values."
        )

    if unchanged_expected:
        LOGGER.warning(
            "Expected sensitive fields came back unchanged: %s",
            ", ".join(unchanged_expected),
        )


def run_poc(
    data_path: Path,
    client: NullafiClient,
    *,
    allow_unchanged_expected: bool = False,
) -> list[dict[str, Any]]:
    """Run the local POC over every fake record."""

    records = read_fake_data(data_path)
    LOGGER.info("Loaded %s fake record(s) from %s", len(records), data_path)

    parsed_results: list[dict[str, Any]] = []
    for record in records:
        payload = build_scan_payload(record)
        LOGGER.info(
            "Scanning record %s with %s non-null field(s)",
            record.record_id,
            len(payload),
        )
        response = client.scan(payload)
        parsed_results.append(parse_scan_response(record, payload, response))

    verify_expected_sensitive_fields(
        parsed_results,
        allow_unchanged_expected=allow_unchanged_expected,
    )
    return parsed_results


def write_results(path: Path, results: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as output_file:
        json.dump(results, output_file, indent=2, sort_keys=True)
        output_file.write("\n")
    LOGGER.info("Wrote normalized POC results to %s", path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Phase 1 Nullafi POC")
    parser.add_argument(
        "--data",
        type=Path,
        default=DEFAULT_DATA_PATH,
        help="Path to the fake sensitive data JSON file",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("phase1_results.json"),
        help="Where to write normalized JSON results",
    )
    parser.add_argument(
        "--allow-unchanged-expected",
        action="store_true",
        help="Warn instead of failing when planted sensitive fields are unchanged",
    )
    parser.add_argument("--verbose", action="store_true", help="Enable debug logs")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    configure_logging(args.verbose)

    if load_dotenv:
        load_dotenv()

    try:
        config = NullafiConfig.from_env()
        client = NullafiClient(config)
        results = run_poc(
            args.data,
            client,
            allow_unchanged_expected=args.allow_unchanged_expected,
        )
        write_results(args.output, results)
    except (AssertionError, NullafiAPIError, ValueError) as exc:
        LOGGER.error("%s", exc)
        return 1

    LOGGER.info("Phase 1 POC completed successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
