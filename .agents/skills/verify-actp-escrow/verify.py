#!/usr/bin/env python3
"""Run bounded models, real-contract conformance and optional mutation controls."""
import argparse
import json
import os
import re
import resource
import shutil
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from doctor import REPO, SKILL, check


def invoke(command, cwd, log, expected=0):
    result = subprocess.run(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=900, check=False)
    log.write_bytes(result.stdout)
    if result.returncode != expected:
        raise RuntimeError(f"{command[0]} exit {result.returncode}, expected {expected}: {log}")
    return result.stdout.decode("utf-8", errors="replace")


def copy_source(destination):
    shutil.copytree(REPO, destination, symlinks=True,
                    ignore=shutil.ignore_patterns(".git", ".env*", "out", "cache",
                                                 "node_modules", "__pycache__"))


def replace_once(path, old, new, scope=None):
    source = path.read_text()
    start = source.index("    function " + scope + "(") if scope else 0
    end = source.find("\n    function ", start + 1) if scope else len(source)
    if end < 0:
        end = len(source)
    part = source[start:end]
    if part.count(old) != 1:
        raise RuntimeError("Mutation anchor drift: " + str(path))
    path.write_text(source[:start] + part.replace(old, new) + source[end:])


def forge_run(source, build, log, forge, solc, match_test=None, expected=0):
    build.mkdir(exist_ok=True)
    args = [
        "/usr/bin/bwrap", "--unshare-all", "--unshare-user", "--die-with-parent", "--new-session",
        "--disable-userns", "--clearenv", "--ro-bind", "/usr", "/usr",
        "--symlink", "usr/bin", "/bin", "--symlink", "usr/lib", "/lib",
        "--symlink", "usr/lib64", "/lib64", "--ro-bind", str(source), "/repo",
        "--ro-bind", str(forge), "/forge", "--ro-bind", str(solc), "/solc",
        "--bind", str(build), "/build", "--proc", "/proc", "--dev", "/dev",
        "--size", "1073741824", "--tmpfs", "/tmp", "--chdir", "/repo",
    ]
    env = {
        "PATH": "/usr/bin:/bin", "HOME": "/tmp", "TMPDIR": "/tmp", "LANG": "C.UTF-8",
        "FOUNDRY_SOLC": "/solc", "FOUNDRY_OFFLINE": "true", "FOUNDRY_ISOLATE": "true",
        "FOUNDRY_TEST": "test/verification", "FOUNDRY_OUT": "/build/out",
        "FOUNDRY_CACHE_PATH": "/build/cache", "FOUNDRY_FUZZ_SEED": "0x9a117",
        "RAYON_NUM_THREADS": "2",
        "FOUNDRY_INVARIANT_FAILURE_PERSIST_DIR": "/build/failures-" + log.stem,
    }
    for key, value in env.items():
        args.extend(["--setenv", key, value])
    args.extend(["/forge", "test", "--offline", "--root", "/repo", "-j", "2", "-vv",
                 "--match-contract", "Escrow(Oracle|Fee)Verification"])
    if match_test:
        args.extend(["--match-test", match_test])

    def limits():
        for limit, value in [(resource.RLIMIT_AS, 16 * 1024**3), (resource.RLIMIT_CPU, 600),
                             (resource.RLIMIT_NPROC, 512), (resource.RLIMIT_FSIZE, 128 * 1024**2),
                             (resource.RLIMIT_NOFILE, 1024)]:
            resource.setrlimit(limit, (value, value))
        os.sched_setaffinity(0, set(sorted(os.sched_getaffinity(0))[:2]))

    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=900, preexec_fn=limits, check=False)
    log.write_bytes(result.stdout)
    text = result.stdout.decode("utf-8", errors="replace")
    if result.returncode != expected or "Compiler run failed" in text:
        raise RuntimeError(f"Forge exit {result.returncode}, expected {expected}: {log}")
    if not match_test and not re.search(r"6 tests passed, 0 failed, 0 skipped", text):
        raise RuntimeError("Conformance test discovery changed: " + str(log))
    return text


def model(harness, source, module, destination, log, expected=0):
    wrapper = harness / "bin/statechart"
    text = invoke([str(wrapper), str(source / (module + ".tla")), "--config",
                   str(source / (module + ".cfg")), "--out", str(destination)],
                  log.parent, log, expected)
    if expected == 1:
        invariant = "OracleAward" if module == "OracleRefund" else "FeeDebtProtected"
        raw = (destination / "tlc.out").read_text()
        if f"Invariant {invariant} is violated" not in raw:
            raise RuntimeError("Model failed without the expected counterexample: " + str(log))
    return text


def controls(out, harness, forge, solc):
    results = []
    for name, module, old, new in [
        ("model-oracle-negative", "OracleRefund",
         "ruling' = [ruling EXCEPT ![t] = verdict]",
         "ruling' = [ruling EXCEPT ![t] = IF winner THEN verdict ELSE 2]"),
        ("model-fee-negative", "FeeDebt",
         "Principal(t) == remaining[t] - debt[t]", "Principal(t) == remaining[t]"),
    ]:
        folder = out / name
        folder.mkdir()
        for suffix in [".tla", ".cfg"]:
            shutil.copyfile(SKILL / (module + suffix), folder / (module + suffix))
        replace_once(folder / (module + ".tla"), old, new)
        model(harness, folder, module, folder / "result", folder / "run.log", 1)
        results.append({"control": name, "expected_violation": True})
    oracle = "invariant_OracleAwardUnaffected"
    fee = "invariant_FeeDebtCannotFundParticipants"
    oracle_test = "test_DeterministicOracleAndRetry"
    fee_test = "test_DeterministicFeePathsAndCounters"
    guard = '        require(!d.resolved, "Already resolved");\n'
    mutations = [
        ("real-oracle-negative", "src/BondEscalation.sol",
         "tier1Refundable[disputeId] = true;",
         "tier1Refundable[disputeId] = true;\n            d.currentRuling = 2;\n            d.splitBps = 5000;",
         oracle_test, "P1 oracle/refund coupling", oracle, None),
        ("real-fee-negative", "src/ACTPKernel.sol",
         "return vault.remaining(txn.escrowId) - pendingPlatformFeeFor[txn.transactionId];",
         "return vault.remaining(txn.escrowId);",
         fee_test, "P2 reserved fee spent", fee, None),
        ("real-oracle-callback-negative", "src/BondEscalation.sol",
         "try compositeMediator.resolve(d.transactionId, d.currentRuling, d.splitBps) {",
         "try compositeMediator.resolve(d.transactionId, 3, d.splitBps) {",
         oracle_test, "P1 callback completion", oracle, "assertionResolvedCallback"),
        ("real-oracle-stale-negative", "src/BondEscalation.sol", guard, "",
         oracle_test, "P1 first-writer guard", oracle, "forceResolveStale"),
        ("real-oracle-sync-negative", "src/BondEscalation.sol", guard,
         '        require(!d.resolved || kernel.getTransaction(d.transactionId).state != '
         'IACTPKernel.State.DISPUTED, "Already resolved");\n',
         oracle_test, "P1 first-writer guard", oracle, "syncExternalResolution"),
        ("real-archive-forwarding-negative", "src/treasury/ArchiveTreasury.sol",
         'require(msg.sender == address(kernel), "Only kernel can deposit");',
         'revert("archive down");', fee_test, "P2 archive forwarding", None, "receiveFunds"),
    ]
    for name, filename, old, new, companion, marker, invariant, scope in mutations:
        snapshot = out / name
        copy_source(snapshot)
        replace_once(snapshot / filename, old, new, scope)
        selection = companion + "|" + invariant if invariant else companion
        text = forge_run(snapshot, out / "build", out / (name + ".log"), forge, solc, selection, 1)
        if f"[FAIL: {marker}] {companion}" not in text:
            raise RuntimeError("Mutation companion failed for a different reason: " + name)
        if invariant:
            event = json.loads(next((line for line in text.splitlines()
                                     if line.startswith("{") and invariant in line), "{}"))
            if (event.get("event") != "failure" or event.get("invariant") != invariant
                    or event.get("reason") != marker):
                raise RuntimeError("Stateful mutation did not fail its property: " + name)
        if scope == "syncExternalResolution" and "P1.accepted-late-after-settlement: 1" not in text:
            raise RuntimeError("Sync control did not reach completed-window acceptance")
        results.append({"control": name, "expected_violation": marker, "invariant": invariant})
    snapshot = out / "real-retry-negative"
    copy_source(snapshot)
    path = snapshot / "src/BondEscalation.sol"
    source = path.read_text()
    start = source.index("    function retryMediatorResolution(")
    end = source.index("    function assertionDisputedCallback(", start)
    part = source[start:end]
    call = "compositeMediator.resolve(d.transactionId, d.currentRuling, d.splitBps);"
    if part.count(call) != 1:
        raise RuntimeError("Retry mutation anchor drift")
    path.write_text(source[:start] + part.replace(call, "return;") + source[end:])
    text = forge_run(snapshot, out / "build", out / "real-retry-negative.log", forge, solc,
                     "test_DeterministicOracleAndRetry", 1)
    if "P1 retry incomplete" not in text:
        raise RuntimeError("Deferred retry negative control missed its target")
    results.append({"control": "real-retry-negative", "expected_violation": "P1 retry incomplete"})
    snapshot = out / "doctor-negative"
    copy_source(snapshot)
    path = snapshot / "src/ACTPKernel.sol"
    path.write_bytes(path.read_bytes() + b"\n")
    text = invoke([sys.executable, str(snapshot / ".agents/skills/verify-actp-escrow/doctor.py")],
                  out, out / "doctor-negative.log", 3)
    if json.loads(text)["status"] != "drift":
        raise RuntimeError("Doctor did not distinguish source drift")
    results.append({"control": "doctor-negative", "expected_status": "drift, not a property violation"})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--harness", type=Path, default=os.environ.get("HARNESS_ROOT"))
    parser.add_argument("--forge", type=Path, default=shutil.which("forge"))
    parser.add_argument("--solc", type=Path, default=shutil.which("solc"))
    parser.add_argument("--negative-controls", action="store_true")
    args = parser.parse_args()
    status, code = check()
    if code:
        print(json.dumps(status))
        return code
    if args.harness is None:
        raise ValueError("Supply --harness or set HARNESS_ROOT to the installed shared Harness")
    args.harness = args.harness.resolve()
    out = args.out.resolve()
    if out.is_relative_to(REPO) or REPO.is_relative_to(out):
        raise ValueError("--out must be outside the repository and cannot contain it")
    out.mkdir(parents=True, exist_ok=False)
    if args.forge is None or args.solc is None:
        raise ValueError("Supply installed --forge and --solc paths")
    forge, solc = args.forge.resolve(), args.solc.resolve()
    version = invoke([str(forge), "--version"], out, out / "forge-version.log")
    if "Version: 1.9.0" not in version:
        raise ValueError("Expected the pinned Forge 1.9.0; re-sync verification before upgrading")
    version = invoke([str(solc), "--version"], out, out / "solc-version.log")
    if "Version: 0.8.34" not in version:
        raise ValueError("Expected solc 0.8.34")
    for module in ["OracleRefund", "FeeDebt"]:
        model(args.harness, SKILL, module, out / module, out / (module + ".log"))
    snapshot = out / "positive"
    copy_source(snapshot)
    text = forge_run(snapshot, out / "build", out / "conformance.log", forge, solc)
    print("\n".join(line for line in text.splitlines() if "P1." in line or "P2." in line))
    result = {"status": "pass", "doctor": status, "models": ["OracleAward", "FeeDebtProtected"],
              "conformance_tests": 6, "negative_controls": []}
    if args.negative_controls:
        result["negative_controls"] = controls(out, args.harness, forge, solc)
    final_status, final_code = check()
    if final_code:
        raise RuntimeError("Source changed during verification: " + json.dumps(final_status))
    result["source_hashes"] = json.loads((SKILL / "coverage.json").read_text())["files"]
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": "pass", "result": str(out / "result.json"),
                      "negative_controls": result["negative_controls"]}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
