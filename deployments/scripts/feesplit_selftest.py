#!/usr/bin/env python3
"""Self-test of the FeeSplitVault acceptance tooling on a local anvil stack.

The reconciler is written by the same builder as the vault, so it is trusted only after it passes
an honest run and catches seeded defects (plan step 12, Phase A gate):

  Honest run, reported without a failure:
    H1 a completed dispute with the bond released to the winner (A9, profile B)
    H2 a split exit with the bond returned to the initiator (A7)
    H3 a plain-vault control (A1)
    H4 a credit retained at one report and withdrawn at the next (A15, then A17)
    H5 one transaction that settles an escrow and withdraws a credit of the same integrator; and
       one that settles with the integrator blocked, unblocks it and withdraws both credits at once
    H6 a stale dispute: pending at the first report, force-resolved and passing at the second
    H7 a donation on its own, and one inside the transaction that links an escrow: surplus
    H8 an escrow of an address outside the manifest, left in COMMITTED: foreign and pending; and
       one whose provider is the kernel, cancelled by its requester: foreign and passing

  Seeded defects, each of which must make the reconciler exit nonzero and report the named check:
    D1 a vault built with a net basis                                  -> C1
    D2 a vault that ignores the disputed flag                          -> C3
    D3 a run file that claims 200 bps for a 100 bps escrow             -> C7a
    D4 a run file that names a plain-vault control never linked        -> C6
    D5 a vault that pays the integrator twice, after a donation        -> C2
    D6 an escrow of a manifest actor deleted from its run file         -> C6

It starts its own anvil, deploys the stack with a blockable token, drives the Arm and Exec
scripts, advances time with evm_increaseTime, and runs deployments/scripts/reconcile_feesplit.py.

A second stage rehearses the Base Sepolia order of work on a fresh anvil: deploy the vault with
DeployFeeSplitVault, gate RECORD with a probe transaction, approve, gate ENFORCE (and a wrong pin
that must be refused), smoke, the whole LIVE matrix at the amounts of the acceptance table, the
negatives probe, the long-running A25, and the reconciliation with --require-complete. It shows
that the scripts run and that every row of the matrix reconciles to its table columns. It is not
testnet evidence.
The scripts write their run files into deployments/feesplit-acceptance/ (the only directory they
may read and write); the self-test moves them to its work directory when it ends. Exit 0 only if
every fixture and every seeded defect behaves as listed.

Usage: python3 deployments/scripts/feesplit_selftest.py [--stage selftest|rehearsal|all] [--work DIR] [--keep]
"""
import argparse
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[2]
RUN_DIR = REPO / "deployments/feesplit-acceptance"
RECONCILE = REPO / "deployments/scripts/reconcile_feesplit.py"
# anvil's well-known development keys (accounts 0-6 of its default mnemonic)
KEYS = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
]
INTEGRATOR = "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"   # anvil account 5
FEE_RECIPIENT = "0x976EA74026E726554dB657fA54763abd0C3a0aa9"  # anvil account 6
DEPLOYER, REQUESTER, PROVIDER, KEEPER, FOREIGN = KEYS

SPLIT = "l.profile == FeeProfile.BOTH_AFTER_DISPUTE && l.disputed && l.bps > 0"
DEFECTIVE_BUILDS = {
    "D1": ("target = (providerSide * bps) / (MAX_BPS - protocolBps);", "target = (providerSide * bps) / MAX_BPS;"),
    "D2": (SPLIT, "l.profile == FeeProfile.BOTH_AFTER_DISPUTE && l.bps > 0"),
    "D5": ("if (token.trySafeTransfer(integrator, amount)) {",
           "if (token.trySafeTransfer(integrator, amount)) {\n            token.trySafeTransfer(integrator, amount);"),
}


class Failure(Exception):
    pass


class SelfTest:
    def __init__(self, work):
        self.work = work
        self.results = []
        self.anvil = None

    # ----- plumbing -----

    def rpc(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            answer = json.loads(response.read())
        if "error" in answer:
            raise Failure(f"{method}: {answer['error']}")
        return answer["result"]

    def block(self):
        return int(self.rpc("eth_blockNumber", []), 16)

    def advance(self, seconds):
        self.rpc("evm_increaseTime", [seconds])
        self.rpc("evm_mine", [])

    def start_anvil(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        self.url = f"http://127.0.0.1:{port}"
        log = open(self.work / "anvil.log", "w")
        self.anvil = subprocess.Popen(["anvil", "--port", str(port), "--silent"], stdout=log, stderr=log)
        for _ in range(100):
            try:
                self.rpc("eth_chainId", [])
                return
            except (OSError, Failure):
                time.sleep(0.1)
        raise Failure("anvil did not start")

    def run(self, name, command, env=None, check=True):
        result = subprocess.run(command, cwd=REPO, env={**os.environ, **(env or {})},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (self.work / f"{name}.log").write_text(result.stdout)
        if check and result.returncode != 0:
            raise Failure(f"{name} failed, see {self.work / (name + '.log')}")
        return result

    def script(self, name, contract, sig, env):
        command = ["forge", "script", f"script/{contract}.s.sol", "--rpc-url", self.url, "--broadcast", "--sig", sig]
        return self.run(name, command, env).stdout

    def cast(self, name, verb, *arguments):
        return self.run(name, ["cast", verb, "--rpc-url", self.url, *arguments]).stdout.strip()

    def run_file(self, name):
        """The run file of set `name` that a script just wrote."""
        files = sorted(RUN_DIR.glob(f"local-{name}-*.json"))
        if len(files) != 1:
            raise Failure(f"expected one run file of set {name}, found {len(files)}")
        return files[0]

    def reconcile(self, name, vault, from_block, runs, extra=()):
        out = self.work / f"{name}.json"
        command = [sys.executable, str(RECONCILE), "--rpc", self.url, "--kernel", self.stack["kernel"],
                   "--vault", vault, "--plain-vault", self.stack["plainVault"], "--token", self.stack["token"],
                   "--from-block", str(from_block), "--out", str(out), *extra]
        for pattern in runs:
            command += ["--runs", str(pattern)]
        result = self.run(name, command, check=False)
        if result.returncode == 2:
            raise Failure(f"reconciler error in {name}, see {self.work / (name + '.log')}")
        return result.returncode, json.loads(out.read_text())

    def expect(self, fixture, what, ok):
        self.results.append((fixture, what, bool(ok)))

    def env(self, vault=None):
        return {
            "FEE_SPLIT_KERNEL": self.stack["kernel"], "FEE_SPLIT_VAULT": vault or self.stack["feeSplitVault"],
            "PLAIN_VAULT": self.stack["plainVault"], "COMPOSITE_MEDIATOR": self.stack["mediator"],
            "BOND_ESCALATION": self.stack["bond"], "REQUESTER_KEY": REQUESTER, "PROVIDER_KEY": PROVIDER,
            "KEEPER_KEY": KEEPER, "ADMIN_KEY": DEPLOYER, "FOREIGN_KEY": FOREIGN, "INTEGRATOR": INTEGRATOR,
        }

    # ----- stages -----

    def build_defective_vaults(self):
        """Compile FeeSplitVault with one defect each, outside the repository."""
        self.bytecode = {}
        for defect, (old, new) in DEFECTIVE_BUILDS.items():
            root = self.work / f"build-{defect}"
            (root / "src").mkdir(parents=True)
            shutil.copytree(REPO / "src/escrow", root / "src/escrow")
            shutil.copytree(REPO / "src/interfaces", root / "src/interfaces")
            for name in ("foundry.toml", "remappings.txt"):
                shutil.copyfile(REPO / name, root / name)
            os.symlink(REPO / "lib", root / "lib")
            path = root / "src/escrow/FeeSplitVault.sol"
            source = path.read_text()
            if source.count(old) != 1:
                raise Failure(f"defect anchor drift: {defect}")
            path.write_text(source.replace(old, new))
            self.run(f"build-{defect}", ["forge", "build", "src/escrow/FeeSplitVault.sol", "--root", str(root)])
            artifact = json.loads((root / "out/FeeSplitVault.sol/FeeSplitVault.json").read_text())
            self.bytecode[defect] = artifact["bytecode"]["object"]

    def deploy(self):
        out = self.script("deploy", "DeployLocalFeeSplitStack", "run()",
                          {"PRIVATE_KEY": DEPLOYER, "FEE_RECIPIENT": FEE_RECIPIENT})
        text = out[out.index("DEPLOY_JSON_BEGIN") + len("DEPLOY_JSON_BEGIN"):out.index("DEPLOY_JSON_END")]
        self.stack = json.loads("".join(line.strip() for line in text.splitlines()))
        self.advance(2 * 86400 + 60)   # the mediator's activation delay
        out = self.script("wallet", "SelfTestFeeSplitLocal", "deployWallet()", self.env())
        self.wallet = next(line.split()[-1] for line in out.splitlines() if line.strip().startswith("WALLET"))

    def honest(self):
        env = dict(self.env(), WALLET=self.wallet)
        out = self.script("arm-honest", "SelfTestFeeSplitLocal", "armHonest()", env)
        kernel_provider_tx = next(line.split()[-1] for line in out.splitlines()
                                  if line.strip().startswith("FOREIGN_KERNEL_PROVIDER_TX"))
        self.script("arm-a25", "SelfTestFeeSplitLocal", "armLongRunning()", env)
        self.selftest_run = self.run_file("selftest")
        self.a25_run = self.run_file("a25")
        pattern = [self.selftest_run, self.a25_run]

        self.advance(9 * 3600)         # past the liveness of the proposed rulings
        self.script("exec-rulings", "AcceptFeeSplitExec", "run()", dict(env, RUN_FILE=str(self.selftest_run)))
        self.script("foreign-cancel", "SelfTestFeeSplitLocal", "foreignCancel()", dict(env, FOREIGN_TX=kernel_provider_tx))

        # First report.
        vault = self.stack["feeSplitVault"]
        code, report = self.reconcile("report-1", vault, 0, pattern)
        entries = {e["label"]: e for e in report["entries"] if e["label"]}
        foreign = [e for e in report["entries"] if e["scope"] == "foreign"]
        self.expect("honest", "first report: exit 0, no failure", code == 0 and report["counts"]["fail"] == 0
                    and not report["globalFailures"])
        self.expect("H1", "A9 (B) pass with the row's columns", entries["H1-A9-B"]["status"] == "pass"
                    and entries["H1-A9-B"]["columns"]["requester"] == 980_000_000)
        self.expect("H2", "A7 pass in both profiles", entries["H2-A7-B"]["status"] == "pass"
                    and entries["H2-A7-D"]["status"] == "pass" and entries["H2-A7-B"]["columns"]["vaultProtocolFee"] == 6_000_000)
        self.expect("H3", "plain-vault control pass", entries["H3-A1"]["status"] == "pass"
                    and entries["H3-A1"]["vault"] == "plain")
        # The integrator stays blocked from H4 on, so the rulings finalized afterwards credit it too:
        # H4 10 + H7 10 + H1 10 + H2 (B) 10 + H2 (D) 4.
        self.expect("H4", "credit retained at the first report",
                    report["credits"]["integrators"].get(INTEGRATOR.lower()) == 44_000_000
                    and entries["H4-credit-A15"]["status"] == "pass"
                    and entries["H4-credit-A15"]["credited"].get("platform") == 10_000_000)
        self.expect("H5", "settle and withdraw in one transaction: pass, one withdrawal of 10.000000",
                    entries["H5-settle-and-withdraw"]["status"] == "pass"
                    and report["withdrawals"][0]["amount"] == 10_000_000)
        self.expect("H5", "credited settlement, unblock and withdrawal of both credits in one transaction: pass",
                    entries["H5-credit-unblock-withdraw"]["status"] == "pass"
                    and entries["H5-credit-unblock-withdraw"]["credited"].get("platform") == 10_000_000
                    and [w["amount"] for w in report["withdrawals"]] == [10_000_000, 20_000_000])
        self.expect("H6", "A25 pending at the first report", entries["H6-A25"]["status"] == "pending")
        self.expect("H7", "both donations reported as surplus, escrows unaffected",
                    report["surplus"]["total"] == 5_000_001 and len(report["surplus"]["transfers"]) == 2
                    and entries["H7-donation-in-link"]["status"] == "pass"
                    and report["solvency"]["balance"] == report["solvency"]["owed"] + 5_000_001)
        open_foreign = [e for e in foreign if e["state"] == "COMMITTED"]
        kernel_provider = [e for e in foreign if e["txId"] == kernel_provider_tx.lower()]
        self.expect("H8", "foreign escrow reported foreign and pending", len(foreign) == 2
                    and len(open_foreign) == 1 and open_foreign[0]["status"] == "pending")
        self.expect("H8", "foreign escrow with the kernel as provider: pass, penalty is a provider payment",
                    len(kernel_provider) == 1 and kernel_provider[0]["status"] == "pass"
                    and kernel_provider[0]["columns"]["provider"] == 49_500_000
                    and kernel_provider[0]["columns"]["kernelFee"] == 500_000)
        code, _ = self.reconcile("report-1-complete", vault, 0, pattern, ["--require-complete"])
        self.expect("H6", "--require-complete fails while A25 is open", code == 1)
        code, _ = self.reconcile("report-1-allowed", vault, 0, pattern,
                                 ["--require-complete", "--allow-pending", "H6-A25"])
        self.expect("H6", "--require-complete passes when A25 is allowed", code == 0)

        # Between the reports: the credit is withdrawn, 30 days pass, the dispute is force-resolved.
        self.script("withdraw", "SelfTestFeeSplitLocal", "withdrawCredit()", env)
        self.advance(30 * 86400 + 660)
        self.script("exec-a25", "AcceptFeeSplitExec", "run()", dict(env, RUN_FILE=str(self.a25_run)))

        code, report = self.reconcile("report-2", vault, 0, pattern, ["--require-complete"])
        entries = {e["label"]: e for e in report["entries"] if e["label"]}
        foreign = [e for e in report["entries"] if e["scope"] == "foreign"]
        self.expect("honest", "second report: exit 0 with --require-complete", code == 0
                    and report["counts"]["fail"] == 0 and not report["globalFailures"])
        self.expect("H4", "credit withdrawn at the second report", not report["credits"]["integrators"]
                    and sorted(w["amount"] for w in report["withdrawals"]) == [10_000_000, 20_000_000, 44_000_000])
        self.expect("H6", "A25 pass with the columns of row A25", entries["H6-A25"]["status"] == "pass"
                    and entries["H6-A25"]["columns"] == {"requester": 490_000_000, "provider": 445_000_000,
                                                         "platform": 55_000_000, "kernelFee": 5_000_000,
                                                         "vaultProtocolFee": 5_000_000, "mediator": 0})
        self.expect("H8", "open foreign escrow still pending and does not block completion",
                    [e["status"] for e in foreign if e["state"] == "COMMITTED"] == ["pending"])
        return pattern

    def missing_manifest(self):
        vault = self.stack["feeSplitVault"]
        code, report = self.reconcile("missing-pattern", vault, 0,
                                      [self.selftest_run, self.a25_run, self.work / "no-such-run-*.json"],
                                      ["--require-complete"])
        self.expect("runs", "a --runs pattern that matches no file fails with C6",
                    code == 1 and "C6" in self.checks(report))
        code, report = self.reconcile("empty-manifest", vault, 0, [self.work / "no-such-run-*.json"],
                                      ["--require-complete"])
        self.expect("runs", "an empty manifest fails with C6", code == 1 and "C6" in self.checks(report))

    def tampered(self, name, mutate):
        """A copy of the honest run files with one of them changed."""
        folder = self.work / f"runs-{name}"
        folder.mkdir()
        shutil.copyfile(self.a25_run, folder / self.a25_run.name)
        path = folder / self.selftest_run.name
        shutil.copyfile(self.selftest_run, path)
        data = json.loads(path.read_text())
        mutate(data)
        data["count"] = len(data["entries"])
        path.write_text(json.dumps(data, indent=2))
        return [folder / "local-*.json"]

    def checks(self, report):
        found = {f["check"] for e in report["entries"] for f in e["failures"]}
        return found | {f["check"] for f in report["globalFailures"]}

    def defect_run_files(self):
        vault = self.stack["feeSplitVault"]

        def claim_200_bps(data):
            next(e for e in data["entries"] if e["label"] == "H1-A9-B")["bps"] = 200

        def name_unlinked_control(data):
            control = dict(next(e for e in data["entries"] if e["label"] == "H3-A1"))
            control.update(label="D4-never-linked", txId="0x" + "d4" * 32)
            data["entries"].append(control)

        def delete_entry(data):
            data["entries"] = [e for e in data["entries"] if e["label"] != "H2-A7-D"]

        for defect, check, mutate in (("D3", "C7a", claim_200_bps), ("D4", "C6", name_unlinked_control),
                                      ("D6", "C6", delete_entry)):
            code, report = self.reconcile(f"defect-{defect}", vault, 0, self.tampered(defect, mutate),
                                          ["--require-complete"])
            self.expect(defect, f"exit nonzero and {check} reported", code == 1 and check in self.checks(report))

    def defect_vaults(self):
        for defect, check in (("D1", "C1"), ("D2", "C3"), ("D5", "C2")):
            start = self.block() + 1
            arguments = self.run(f"args-{defect}", ["cast", "abi-encode", "constructor(address,address)",
                                                    self.stack["token"], self.stack["kernel"]]).stdout.strip()
            receipt = json.loads(self.cast(f"deploy-{defect}", "send", "--private-key", DEPLOYER, "--json",
                                           "--create", self.bytecode[defect] + arguments[2:]))
            vault = receipt["contractAddress"]
            self.cast(f"approve-{defect}", "send", "--private-key", DEPLOYER, self.stack["kernel"],
                      "approveEscrowVault(address,bool)", vault, "true")
            if defect == "D5":      # a donation, so that the second transfer succeeds
                self.cast("donate-D5", "send", "--private-key", KEEPER, self.stack["token"],
                          "mint(address,uint256)", vault, "100000000")
            self.script(f"arm-{defect}", "SelfTestFeeSplitLocal", "armDefect()", dict(self.env(vault), DEFECT=defect))
            code, report = self.reconcile(f"defect-{defect}", vault, start,
                                          [self.run_file(f"defect-{defect.lower()}")], ["--require-complete"])
            self.expect(defect, f"exit nonzero and {check} reported", code == 1 and check in self.checks(report))

    # ----- rehearsal of the testnet order of work -----

    def stop_anvil(self):
        if self.anvil:
            self.anvil.terminate()
            self.anvil.wait()
            self.anvil = None

    def stash_runs(self, name):
        folder = self.work / name
        folder.mkdir(exist_ok=True)
        for path in RUN_DIR.glob("local-*.json"):
            shutil.move(str(path), folder / path.name)

    def gate(self, name, vault, probe, pins=None, check=True):
        env = {"FEE_SPLIT_KERNEL": self.stack["kernel"], "FEE_SPLIT_VAULT": vault, "PROBE_TX": probe,
               "COMPOSITE_MEDIATOR": self.stack["mediator"], "BOND_ESCALATION": self.stack["bond"], **(pins or {})}
        command = ["forge", "script", "script/VerifyFeeSplitGate.s.sol", "--rpc-url", self.url]
        return self.run(name, command, env, check=check)

    def codehash(self, address):
        code = self.rpc("eth_getCode", [address, "latest"])
        return self.run("keccak", ["cast", "keccak", code]).stdout.strip()

    def rehearsal(self):
        self.start_anvil()
        out = self.script("r-deploy-stack", "DeployLocalFeeSplitStack", "run()",
                          {"PRIVATE_KEY": DEPLOYER, "FEE_RECIPIENT": FEE_RECIPIENT})
        text = out[out.index("DEPLOY_JSON_BEGIN") + len("DEPLOY_JSON_BEGIN"):out.index("DEPLOY_JSON_END")]
        self.stack = json.loads("".join(line.strip() for line in text.splitlines()))
        self.advance(2 * 86400 + 60)

        # Deploy only: the vault is inert until the admin approves it.
        out = self.script("r-deploy-vault", "DeployFeeSplitVault", "run()",
                          {"PRIVATE_KEY": KEEPER, "FEE_SPLIT_KERNEL": self.stack["kernel"]})
        vault = next(line.split()[-1] for line in out.splitlines() if line.strip().startswith("vault "))
        env = self.env(vault)
        approved = self.cast("r-approved-0", "call", self.stack["kernel"], "approvedEscrowVaults(address)(bool)", vault)
        self.expect("deploy", "DeployFeeSplitVault deploys without approving", approved == "false")

        # A plain-vault control gives the gate its probe transaction.
        self.script("r-arm-probe", "AcceptFeeSplitArm", "run()", dict(env, ACCEPT_ROWS="A1", ACCEPT_SET="probe"))
        probe = json.loads(self.run_file("probe").read_text())["entries"][0]["txId"]
        record = self.gate("r-gate-record", vault, probe)
        self.expect("gate", "RECORD passes on the unapproved, empty vault", "GATE PASSED" in record.stdout)
        self.cast("r-approve", "send", "--private-key", DEPLOYER, self.stack["kernel"],
                  "approveEscrowVault(address,bool)", vault, "true")
        pins = {"EXPECTED_KERNEL_CODEHASH": self.codehash(self.stack["kernel"]),
                "EXPECTED_MEDIATOR_CODEHASH": self.codehash(self.stack["mediator"]),
                "EXPECTED_BOND_CODEHASH": self.codehash(self.stack["bond"]),
                "EXPECTED_FEE_SPLIT_CODEHASH": self.codehash(vault)}
        enforce = self.gate("r-gate-enforce", vault, probe, pins)
        self.expect("gate", "ENFORCE passes with the recorded codehashes",
                    "GATE PASSED" in enforce.stdout and enforce.stdout.count("OK  ENFORCE") == 4)
        wrong = self.gate("r-gate-wrong-pin", vault, probe,
                          dict(pins, EXPECTED_FEE_SPLIT_CODEHASH="0x" + "11" * 32), check=False)
        self.expect("gate", "ENFORCE refuses another vault codehash",
                    wrong.returncode != 0 and "GATE: vault codehash mismatch" in wrong.stdout)

        # Smoke: arm, wait for liveness and the deadline, exec, reconcile.
        self.script("r-smoke-arm", "SmokeFeeSplit", "run()", dict(env, SMOKE_STAGE="arm"))
        smoke = self.run_file("smoke")
        early = self.run("r-smoke-early", ["forge", "script", "script/SmokeFeeSplit.s.sol", "--rpc-url", self.url,
                                           "--broadcast"], dict(env, SMOKE_STAGE="exec", RUN_FILE=str(smoke)), check=False)
        self.expect("smoke", "Exec refuses to run before the recorded time",
                    early.returncode != 0 and "too early for" in early.stdout)
        self.advance(3 * 3600)
        self.script("r-smoke-exec", "SmokeFeeSplit", "run()", dict(env, SMOKE_STAGE="exec", RUN_FILE=str(smoke)))
        pattern = [RUN_DIR / "local-*.json"]
        code, report = self.reconcile("r-report-smoke", vault, 0, pattern, ["--require-complete"])
        self.expect("smoke", "smoke and probe entries reconcile to the fee rules",
                    code == 0 and report["counts"]["pass"] == 9 and report["counts"]["fail"] == 0)

        # The LIVE matrix at the amounts of the acceptance table.
        self.script("r-arm-matrix", "AcceptFeeSplitArm", "run()", env)
        matrix = self.run_file("matrix")
        self.advance(9 * 3600)
        self.script("r-exec-matrix", "AcceptFeeSplitExec", "run()", dict(env, RUN_FILE=str(matrix)))
        self.script("r-arm-a25", "AcceptFeeSplitArm", "armLongRunning()", env)
        negatives = self.run("r-negatives", ["forge", "script", "script/AcceptFeeSplitArm.s.sol", "--rpc-url", self.url,
                                             "--sig", "probeNegatives()"], env)
        evidence = json.loads(next(RUN_DIR.glob("local-negatives-*.json")).read_text())
        self.expect("negatives", "A23 and the consent negatives revert with the expected reasons, nothing broadcast",
                    negatives.returncode == 0 and evidence["count"] == 16 and evidence["balancesUnchanged"])

        code, report = self.reconcile("r-report-matrix", vault, 0, pattern,
                                      ["--require-complete", "--allow-pending", "A25"])
        rows = [e for e in report["entries"] if e["row"]]
        expected = len(json.loads(matrix.read_text())["entries"])
        self.expect("matrix", f"all {expected} matrix entries pass with their table columns; only A25 is open",
                    code == 0 and report["counts"]["fail"] == 0 and not report["globalFailures"]
                    and sum(e["status"] == "pass" for e in rows) == expected + 1      # + the probe control A1
                    and [e["label"] for e in rows if e["status"] == "pending"] == ["A25"])
        self.expect("matrix", "the negatives file is listed as evidence, not as a run file",
                    [e["kind"] for e in report["evidenceFiles"]] == ["negatives"])
        code, _ = self.reconcile("r-report-matrix-strict", vault, 0, pattern, ["--require-complete"])
        self.expect("matrix", "--require-complete without the allowance fails while A25 is open", code == 1)

        self.advance(30 * 86400 + 660)
        self.script("r-exec-a25", "AcceptFeeSplitExec", "run()", dict(env, RUN_FILE=str(self.run_file("a25"))))
        code, report = self.reconcile("r-report-final", vault, 0, pattern, ["--require-complete"])
        self.expect("matrix", "after 30 days A25 is force-resolved and everything is complete",
                    code == 0 and report["counts"]["pending"] == 0 and report["counts"]["fail"] == 0)

    def main(self, stage):
        if list(RUN_DIR.glob("local-*.json")):
            raise Failure(f"stale local run files in {RUN_DIR}; remove them first")
        if stage in ("selftest", "all"):
            self.build_defective_vaults()
            self.start_anvil()
            self.deploy()
            self.honest()
            self.missing_manifest()
            self.defect_run_files()
            self.defect_vaults()
            self.stop_anvil()
            self.stash_runs("runs-selftest")
        if stage in ("rehearsal", "all"):
            self.rehearsal()
            self.stop_anvil()
            self.stash_runs("runs-rehearsal")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stage", choices=["selftest", "rehearsal", "all"], default="all")
    parser.add_argument("--work", type=pathlib.Path, help="work directory outside the repository (default: a temp dir)")
    parser.add_argument("--keep", action="store_true", help="keep the work directory")
    args = parser.parse_args()
    work = (args.work or pathlib.Path(tempfile.mkdtemp(prefix="feesplit-selftest-"))).resolve()
    if work.is_relative_to(REPO):
        print("--work must be outside the repository", file=sys.stderr)
        return 2
    work.mkdir(parents=True, exist_ok=True)
    test = SelfTest(work)
    error = None
    try:
        test.main(args.stage)
    except Failure as failure:
        error = str(failure)
    finally:
        test.stop_anvil()
        test.stash_runs("runs-aborted")     # never leave local run files in the repository
    for fixture, what, ok in test.results:
        print(f"{'ok  ' if ok else 'FAIL'}  {fixture:7} {what}")
    passed = sum(ok for _, _, ok in test.results)
    print(f"{passed}/{len(test.results)} expectations met; work directory {work}")
    if error:
        print(f"aborted: {error}", file=sys.stderr)
    success = error is None and test.results and passed == len(test.results)
    if success and not args.keep and args.work is None:
        shutil.rmtree(work)
    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
