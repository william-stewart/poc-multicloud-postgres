#!/usr/bin/env python3
"""Check that per-cloud module implementations honor their shared interface.

For every infra/modules/<name>/contract.json, each subdirectory of
infra/modules/<name>/ that contains .tf files is an implementation. It must
declare every contract input (with the same type) and every contract output.
Implementations may declare extra, cloud-specific inputs and outputs.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BLOCK = re.compile(r'^(variable|output)\s+"([^"]+)"\s*\{', re.MULTILINE)
TYPE = re.compile(r"^\s*type\s*=\s*(.+?)\s*$", re.MULTILINE)


def declarations(module_dir: Path) -> tuple[dict[str, str | None], set[str]]:
    """Return ({variable: type}, {output}) declared in a module directory."""
    variables: dict[str, str | None] = {}
    outputs: set[str] = set()
    for tf in sorted(module_dir.glob("*.tf")):
        text = tf.read_text()
        blocks = list(BLOCK.finditer(text))
        for i, block in enumerate(blocks):
            kind, name = block.groups()
            if kind == "output":
                outputs.add(name)
                continue
            end = blocks[i + 1].start() if i + 1 < len(blocks) else len(text)
            type_match = TYPE.search(text, block.end(), end)
            variables[name] = re.sub(r"\s+", "", type_match.group(1)) if type_match else None
    return variables, outputs


def check(contract_file: Path) -> list[str]:
    contract = json.loads(contract_file.read_text())
    expected_inputs: dict[str, str] = contract["inputs"]
    expected_outputs: list[str] = contract["outputs"]
    impls = sorted(d for d in contract_file.parent.iterdir() if d.is_dir() and any(d.glob("*.tf")))

    errors = []
    if len(impls) < 2:
        errors.append(f"{contract_file.parent.relative_to(ROOT)}: a shared interface needs at least two implementations")
    for impl in impls:
        rel = impl.relative_to(ROOT)
        variables, outputs = declarations(impl)
        for name, want in expected_inputs.items():
            if name not in variables:
                errors.append(f"{rel}: missing input '{name}'")
            elif variables[name] != re.sub(r"\s+", "", want):
                errors.append(f"{rel}: input '{name}' has type {variables[name]}, contract says {want}")
        for name in expected_outputs:
            if name not in outputs:
                errors.append(f"{rel}: missing output '{name}'")
    return errors


def main() -> int:
    contracts = sorted(ROOT.glob("infra/modules/*/contract.json"))
    errors = [e for c in contracts for e in check(c)]
    for e in errors:
        print(f"contract violation: {e}", file=sys.stderr)
    if not errors:
        print(f"{len(contracts)} module contract(s) satisfied")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
