"""OpenAPI snapshot regression (agentero plan T4.1).

The backend's OpenAPI document is frozen in ``openapi_snapshot.json``; any
schema change fails this test until the snapshot is consciously refreshed in
the same commit:

    UPDATE_SNAPSHOT=1 .venv/bin/python -m pytest tests/test_openapi_snapshot.py

The client-side twin (schema fields mirrored by the Swift models) lives in
``macos/scripts/check_api_contract.py``.
"""

import json
import os
import unittest
from pathlib import Path

from app.main import app

SNAPSHOT_PATH = Path(__file__).with_name("openapi_snapshot.json")


class OpenApiSnapshotTests(unittest.TestCase):
    def test_openapi_document_matches_snapshot(self):
        current = json.dumps(app.openapi(), sort_keys=True, ensure_ascii=False)
        if os.environ.get("UPDATE_SNAPSHOT") == "1":
            SNAPSHOT_PATH.write_text(current, encoding="utf-8")
        self.assertTrue(
            SNAPSHOT_PATH.exists(),
            "missing tests/openapi_snapshot.json — generate with UPDATE_SNAPSHOT=1 pytest",
        )
        recorded = SNAPSHOT_PATH.read_text(encoding="utf-8")
        self.assertEqual(current, recorded)


if __name__ == "__main__":
    unittest.main()
