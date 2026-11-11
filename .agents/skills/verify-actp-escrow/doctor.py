#!/usr/bin/env python3
"""Check verification assets and drift without making a property claim."""
import hashlib
import json
import re
from pathlib import Path

SKILL = Path(__file__).resolve().parent
REPO = SKILL.parents[2]
REQUIRED = {
    "src/ACTPKernel.sol", "src/BondEscalation.sol", "src/CompositeMediator.sol",
    "src/escrow/EscrowVault.sol", "src/treasury/ArchiveTreasury.sol",
    "foundry.toml", "docs/INVARIANT-COVERAGE.md",
    ".agents/skills/verify-actp-escrow/doctor.py",
    ".agents/skills/verify-actp-escrow/verify.py", "src/interfaces/IACTPKernel.sol",
    "src/interfaces/IEscrowValidator.sol", "src/interfaces/ICompositeMediator.sol",
    "test/helpers/DisputeTestBase.sol", "test/mocks/MockOOV3.sol",
    "test/audit/F17F59_FeeAccounting.t.sol",
    "test/verification/EscrowOracle.t.sol", "test/verification/EscrowFees.t.sol",
    "src/escrow/FeeSplitVault.sol", "src/interfaces/IFeeSplitVault.sol",
    "test/verification/EscrowSplit.t.sol",
    ".agents/skills/verify-actp-escrow/FeeSplit.tla",
    ".agents/skills/verify-actp-escrow/FeeSplitDefault.cfg",
    ".agents/skills/verify-actp-escrow/FeeSplitBoth.cfg",
    ".agents/skills/verify-actp-escrow/OracleRefund.tla",
    ".agents/skills/verify-actp-escrow/OracleRefund.cfg",
    ".agents/skills/verify-actp-escrow/FeeDebt.tla",
    ".agents/skills/verify-actp-escrow/FeeDebt.cfg",
    ".agents/skills/verify-actp-escrow/SKILL.md",
    ".agents/skills/verify-actp-escrow/WRITERS.md",
}


def check():
    errors, drift = [], []
    record = SKILL / "coverage.json"
    if not record.is_file():
        return {"status": "missing", "errors": ["coverage.json missing"], "drift": []}, 2
    try:
        data = json.loads(record.read_text())
        if data["version"] != 1 or (SKILL / data["repo"]).resolve() != REPO:
            errors.append("Invalid coverage schema or repository root")
        entries = data["files"]
        if not isinstance(entries, dict):
            raise ValueError("Coverage files must be an object")
        for name in sorted(REQUIRED - entries.keys()):
            errors.append("Missing coverage entry: " + name)
        for name, expected in entries.items():
            if not isinstance(name, str) or not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                raise ValueError("Invalid coverage path or SHA256")
            path = (REPO / name).resolve()
            if not path.is_relative_to(REPO) or not path.is_file():
                errors.append("Missing or escaping covered file: " + name)
            elif hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                drift.append(name)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        errors.append(str(exc))
    try:
        text = (REPO / "docs/INVARIANT-COVERAGE.md").read_text()
        sources = "\n".join(p.read_text() for p in (REPO / "test").rglob("*.sol"))
        for line in text.splitlines():
            if line.startswith(("INV-12 ", "INV-22 ", "INV-32 ", "INV-33 ", "INV-34 ", "INV-35 ",
                                "INV-36 ", "INV-37 ", "INV-38 ", "INV-39 ")):
                for test in re.findall(r"::((?:test|testFuzz|invariant)_[A-Za-z0-9_]+)", line):
                    if not re.search(r"function\s+" + re.escape(test) + r"\s*\(", sources):
                        errors.append("Missing cited Solidity test: " + test)
    except OSError as exc:
        errors.append(str(exc))
    link = REPO / ".claude/skills/verify-actp-escrow"
    if not link.is_symlink() or link.readlink().is_absolute() or link.resolve() != SKILL:
        errors.append("Missing or incorrect relative Claude skill symlink")
    status = "missing" if errors else ("drift" if drift else "synced")
    return {"status": status, "errors": errors, "drift": drift}, (2 if errors else (3 if drift else 0))


if __name__ == "__main__":
    result, code = check()
    print(json.dumps(result, indent=2))
    raise SystemExit(code)
