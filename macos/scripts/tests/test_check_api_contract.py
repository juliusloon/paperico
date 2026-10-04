from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CHECKER = ROOT / "macos/scripts/check_api_contract.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("paperico_check_api_contract", CHECKER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {CHECKER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECKER_MODULE = load_checker()


def object_schema(fields: set[str]) -> dict:
    return {"type": "object", "properties": {field: {} for field in sorted(fields)}}


def synthetic_document(settings_fields: set[str] | None = None) -> dict:
    schemas = {
        name: object_schema(fields)
        for name, fields in CHECKER_MODULE.SNAPSHOT.items()
    }
    if settings_fields is not None:
        schemas[CHECKER_MODULE.SETTINGS_SCHEMA] = object_schema(settings_fields)
    return {"components": {"schemas": schemas}}


class CheckAPIContractToolTests(unittest.TestCase):
    def run_checker(self, document: dict, *arguments: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = Path(temp_dir) / "openapi.json"
            fixture.write_text(json.dumps(document), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), "--file", str(fixture), *arguments],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

    @unittest.skipUnless(
        (ROOT / "backend/tests/openapi_snapshot.json").is_file(),
        "Retired backend snapshot is optional and no longer ships in this repository",
    )
    def test_local_backend_contract_when_available(self) -> None:
        document = json.loads((ROOT / "backend/tests/openapi_snapshot.json").read_text(encoding="utf-8"))
        result = self.run_checker(document)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_normal_payload_and_update_use_supplied_fields(self) -> None:
        document = synthetic_document(CHECKER_MODULE.SNAPSHOT_FIELDS)
        result = self.run_checker(document)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("contract OK", result.stdout)

        changed = synthetic_document(CHECKER_MODULE.SNAPSHOT_FIELDS)
        changed["components"]["schemas"]["ProjectOut"]["properties"]["future_field"] = {}
        update = self.run_checker(changed, "--update")
        self.assertEqual(update.returncode, 0, update.stdout + update.stderr)
        rendered = json.loads(update.stdout)
        self.assertIn("future_field", rendered["ProjectOut"])
        self.assertEqual(rendered[CHECKER_MODULE.SETTINGS_SCHEMA], sorted(CHECKER_MODULE.SNAPSHOT_FIELDS))

    def test_missing_settings_field_is_reported(self) -> None:
        fields = set(CHECKER_MODULE.SNAPSHOT_FIELDS)
        fields.remove("mineru")
        result = self.run_checker(synthetic_document(fields))
        self.assertEqual(result.returncode, 1)
        self.assertIn("AppSettingsOut: settings keys REMOVED", result.stdout)

    def test_added_settings_field_is_reported(self) -> None:
        fields = set(CHECKER_MODULE.SNAPSHOT_FIELDS) | {"future_settings"}
        result = self.run_checker(synthetic_document(fields))
        self.assertEqual(result.returncode, 1)
        self.assertIn("AppSettingsOut: settings keys ADDED", result.stdout)

    def test_unrelated_settings_superset_does_not_match(self) -> None:
        document = synthetic_document()
        document["components"]["schemas"]["AppSettingsUpdate"] = object_schema(CHECKER_MODULE.SNAPSHOT_FIELDS)
        result = self.run_checker(document)
        self.assertEqual(result.returncode, 1)
        self.assertIn("AppSettingsOut: schema missing", result.stdout)


if __name__ == "__main__":
    unittest.main()
