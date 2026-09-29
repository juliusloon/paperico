"""Discovery and validation helpers for MinerU.Chem result bundles.

MinerU.Chem currently stores both public-facing summary lists in
``demonstration_tables.json``.  Keeping the adapter isolated makes schema
drift visible without coupling the generic MinerU block parser to an
undocumented API contract.
"""

from __future__ import annotations

import json

from ..core.status import ErrorCode
from pathlib import Path
from typing import Any


CHEM_SUMMARY_FILENAME = "demonstration_tables.json"
CHEM_MOLECULE_RAW_FILENAME = "apicall_mol.json"


class MinerUChemUnavailable(RuntimeError):
    error_code = ErrorCode.MINERU_SUBMIT_FAILED
    """Raised when MinerU accepted a normal task but did not start Chem."""


class MinerUChemSchemaError(ValueError):
    error_code = ErrorCode.JSON_PARSE_FAILED
    """Raised when a downloaded Chem bundle does not match the observed schema."""


def find_chem_summary(output_dir: str | Path) -> str:
    """Locate MinerU.Chem's consolidated molecule/reaction summary file."""
    root = Path(output_dir)
    if not root.exists():
        return ""
    candidates = sorted(
        root.rglob(CHEM_SUMMARY_FILENAME),
        key=lambda path: (len(path.relative_to(root).parts), path.as_posix()),
    )
    return str(candidates[0]) if candidates else ""


def load_chem_summary(path_or_dir: str | Path) -> dict[str, Any]:
    """Load and validate the observed ``demonstration_tables.json`` schema."""
    source = Path(path_or_dir)
    if source.is_dir():
        found = find_chem_summary(source)
        if not found:
            raise MinerUChemSchemaError(
                f"MinerU.Chem bundle is missing {CHEM_SUMMARY_FILENAME}"
            )
        source = Path(found)

    try:
        payload = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MinerUChemSchemaError(f"Unable to read MinerU.Chem summary: {exc}") from exc

    if not isinstance(payload, dict):
        raise MinerUChemSchemaError("MinerU.Chem summary must be a JSON object")

    molecule_table = _validate_table(
        payload.get("molecule_table"),
        table_name="molecule_table",
        required_columns={"mol_id", "mol_smiles", "mol_molfile", "page_idx", "page_bbox"},
    )
    reaction_table = _validate_table(
        payload.get("reaction_table"),
        table_name="reaction_table",
        required_columns={
            "reaction_id", "reaction_conditions", "reactants", "products", "page_idx"
        },
    )

    summary = payload.get("summary")
    if summary is not None and not isinstance(summary, dict):
        raise MinerUChemSchemaError("MinerU.Chem summary.summary must be an object")

    # Preserve the provider payload verbatim.  The local data model and review
    # state should be layered on top instead of overwriting recognition output.
    payload["molecule_table"] = molecule_table
    payload["reaction_table"] = reaction_table
    return payload


def inspect_chem_bundle(path_or_dir: str | Path) -> dict[str, Any]:
    """Return counts, columns, and missing referenced artifacts for a bundle."""
    source = Path(path_or_dir)
    if source.is_dir():
        found = find_chem_summary(source)
        if not found:
            raise MinerUChemSchemaError(
                f"MinerU.Chem bundle is missing {CHEM_SUMMARY_FILENAME}"
            )
        summary_path = Path(found)
    else:
        summary_path = source
    payload = load_chem_summary(summary_path)
    root = summary_path.parent
    molecules = payload["molecule_table"]["data"]
    reactions = payload["reaction_table"]["data"]

    artifact_paths: set[str] = set()
    for molecule in molecules:
        if isinstance(molecule, dict):
            _add_relative_artifact(artifact_paths, molecule.get("mol_img"))
            _add_relative_artifact(artifact_paths, molecule.get("mol_graph"))
    for reaction in reactions:
        if not isinstance(reaction, dict):
            continue
        _add_relative_artifact(artifact_paths, reaction.get("reaction_figure"))
        for role_key in ("reactants_smiles", "products_smiles"):
            role_entries = reaction.get(role_key, [])
            if not isinstance(role_entries, list):
                continue
            for wrapper in role_entries:
                if not isinstance(wrapper, dict):
                    continue
                for participant in wrapper.values():
                    if isinstance(participant, dict):
                        _add_relative_artifact(artifact_paths, participant.get("crop_path"))

    missing = sorted(path for path in artifact_paths if not (root / path).is_file())
    provider_summary = payload.get("summary") or {}
    return {
        "summary_path": str(summary_path),
        "molecule_count": len(molecules),
        "reaction_count": len(reactions),
        "reported_molecule_count": provider_summary.get("total_molecules"),
        "reported_reaction_count": provider_summary.get("total_reactions"),
        "molecule_columns": payload["molecule_table"]["columns"],
        "reaction_columns": payload["reaction_table"]["columns"],
        "referenced_artifact_count": len(artifact_paths),
        "missing_artifacts": missing,
    }


def _validate_table(
    value: Any,
    *,
    table_name: str,
    required_columns: set[str],
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise MinerUChemSchemaError(f"MinerU.Chem summary.{table_name} must be an object")
    columns = value.get("columns")
    data = value.get("data")
    if not isinstance(columns, list) or not all(isinstance(column, str) for column in columns):
        raise MinerUChemSchemaError(f"MinerU.Chem {table_name}.columns must be a string array")
    if not isinstance(data, list) or not all(isinstance(row, dict) for row in data):
        raise MinerUChemSchemaError(f"MinerU.Chem {table_name}.data must be an object array")
    missing = sorted(required_columns.difference(columns))
    if missing:
        raise MinerUChemSchemaError(
            f"MinerU.Chem {table_name} is missing required columns: {', '.join(missing)}"
        )
    return value


def _add_relative_artifact(paths: set[str], value: Any) -> None:
    if not isinstance(value, str) or not value.strip():
        return
    candidate = Path(value)
    if candidate.is_absolute() or ".." in candidate.parts:
        return
    paths.add(candidate.as_posix())
