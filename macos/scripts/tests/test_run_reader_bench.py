from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
BENCH = ROOT / "macos/scripts/run_reader_bench.sh"


def synthetic_detail() -> dict:
    return {
        "paper": {
            "id": "synthetic-paper",
            "title": "Synthetic benchmark paper",
            "title_zh": "",
            "authors": [],
            "year": None,
            "domain_tags": [],
            "status": "ready",
            "project_id": None,
            "source_type": "upload",
            "original_file_name": "synthetic.pdf",
            "created_at": "2026-10-03T00:00:00Z",
            "last_opened_at": None,
            "tldr": "",
            "narrative_summary": "",
            "contributions": [],
            "difficulty_estimate": "",
            "venue": "",
            "error_message": "",
            "error_code": None,
        },
        "blocks": [
            {
                "id": "block-1",
                "order": 0,
                "kind": "paragraph",
                "page_idx": 0,
                "bbox": None,
                "section_title": "",
                "text_original": "# Heading\n\n1. ordered item",
                "text_zh": "译文",
                "one_liner": "",
                "keywords": [],
                "role_in_narrative": "",
                "image_path": "",
                "caption_original": "",
                "caption_zh": "",
                "figure_type": "",
                "core_takeaways": [],
                "data_reading_notes": "",
                "table_html": "<table><tr><td>A</td></tr></table>",
                "latex": "",
                "plain_explanation": "",
                "entity_refs": [],
            }
        ],
        "entities": [],
    }


class ReaderBenchToolTests(unittest.TestCase):
    def test_normal_synthetic_payload(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("focused reader benchmark requires macOS")
        self.assertIsNotNone(shutil.which("xcrun"), "macOS tool regression checks require Xcode")
        with tempfile.TemporaryDirectory() as temp_dir:
            payload = Path(temp_dir) / "detail.json"
            payload.write_text(json.dumps(synthetic_detail()), encoding="utf-8")
            environment = os.environ.copy()
            if Path("/Applications/Xcode.app").is_dir():
                environment.pop("DEVELOPER_DIR", None)
            result = subprocess.run(
                [str(BENCH), str(payload)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("block 数 = 1", result.stdout)

    def test_compile_failure_never_runs_stale_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            fake_bin = temp / "bin"
            fake_bin.mkdir()
            fake_xcrun = fake_bin / "xcrun"
            fake_xcrun.write_text(
                "#!/bin/sh\n"
                "output=\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "  if [ \"$1\" = \"-o\" ]; then shift; output=$1; fi\n"
                "  shift\n"
                "done\n"
                "printf '#!/bin/sh\\necho STALE_BENCHMARK_RAN\\n' > \"$output\"\n"
                "chmod +x \"$output\"\n"
                "echo synthetic compiler failure >&2\n"
                "exit 91\n",
                encoding="utf-8",
            )
            fake_xcrun.chmod(0o755)
            payload = temp / "detail.json"
            payload.write_text("{}", encoding="utf-8")
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
            result = subprocess.run(
                [str(BENCH), str(payload)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 91, combined)
        self.assertNotIn("STALE_BENCHMARK_RAN", combined)
        self.assertNotIn("运行:", result.stdout)

    def test_selected_custom_xcode_is_not_overridden(self) -> None:
        if not Path("/Applications/Xcode.app").is_dir():
            self.skipTest("coexisting Xcode regression requires the default installation")
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            fake_bin = temp / "bin"
            fake_bin.mkdir()
            selected = fake_bin / "xcode-select"
            selected.touch()
            selected.chmod(0o755)
            compiler = fake_bin / "xcrun"
            compiler.write_text(
                "#!/bin/sh\n"
                "[ \"${DEVELOPER_DIR:-}\" = \"$BENCH_EXPECTED_DEVELOPER_DIR\" ] || exit 92\n"
                "output=\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "  if [ \"$1\" = \"-o\" ]; then shift; output=$1; fi\n"
                "  shift\n"
                "done\n"
                "printf '#!/bin/sh\\nexit 0\\n' > \"$output\"\n"
                "chmod +x \"$output\"\n"
            )
            compiler.chmod(0o755)
            payload = temp / "detail.json"
            payload.write_text("{}")
            cases = [
                ("/Applications/CustomXcode.app/Contents/Developer", "", ""),
                ("/Applications/CustomCommandLineToolsXcode.app/Contents/Developer", "", ""),
                ("/Library/Developer/CommandLineTools", "/Applications/ExplicitXcode.app/Contents/Developer",
                 "/Applications/ExplicitXcode.app/Contents/Developer"),
                ("/Library/Developer/CommandLineTools", "", "/Applications/Xcode.app/Contents/Developer"),
            ]
            for selected_path, explicit, expected in cases:
                with self.subTest(selected=selected_path, explicit=explicit):
                    selected.write_text(f"#!/bin/sh\necho {selected_path}\n")
                    environment = os.environ.copy()
                    environment.pop("DEVELOPER_DIR", None)
                    if explicit:
                        environment["DEVELOPER_DIR"] = explicit
                    environment["BENCH_EXPECTED_DEVELOPER_DIR"] = expected
                    environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
                    result = subprocess.run([str(BENCH), str(payload)], cwd=ROOT, env=environment,
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
