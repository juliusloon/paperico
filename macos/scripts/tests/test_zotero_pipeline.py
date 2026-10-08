"""A real production pipeline with an in-memory HTTP provider; never calls paid services."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[3]


class ZoteroPipelineTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "native pipeline requires macOS")
    def test_imported_authority_survives_production_pipeline(self):
        environment = os.environ.copy()
        if Path("/Applications/Xcode.app").is_dir():
            environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
        with tempfile.TemporaryDirectory(prefix="paperico-zotero-pipeline-") as temp:
            work = Path(temp)
            export = work / "export"
            export.mkdir()
            (export / "authority.pdf").write_bytes(b"%PDF-1.7\nauthority fixture")
            (export / "export.bib").write_text("@article{a,title={Authority title},author={User, Ada},year={2021},journal={Authority Journal},doi={10.5555/authority},eprint={2101.00001},file={authority.pdf}}", encoding="utf-8")
            with zipfile.ZipFile(work / "results.zip", "w", zipfile.ZIP_STORED) as archive:
                archive.writestr("content_list.json", json.dumps([{"type": "text", "text": "The experimental method provides reproducible evidence.", "page_idx": 0}]))
            package = json.loads(subprocess.check_output(["swift", "package", "--package-path", str(ROOT / "macos"), "describe", "--type", "json"], env=environment))
            core = next(target for target in package["targets"] if target["name"] == "PapericoCore")
            sources = [str(ROOT / "macos" / core["path"] / source) for source in core["sources"]]
            sources += [str(ROOT / "macos/Paperico" / source) for source in ["Core/PaperPipeline.swift", "Stores/SettingsStore.swift", "Support/LocalPrefs.swift"]]
            sources.append(str(Path(__file__).with_name("ZoteroPipelineRegression.swift")))
            binary = work / "verify-zotero-pipeline"
            built = subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-o", str(binary), *sources], env=environment, capture_output=True, text=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary), str(work)], env=environment, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("six metadata fields retained", result.stdout)
