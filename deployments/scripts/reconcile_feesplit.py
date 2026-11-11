#!/usr/bin/env python3
"""Reconcile FeeSplitVault escrows against the fee rules, from independent sources.

What it establishes, for every escrow in scope at the end block (checks C1-C7 of the plan):
  C1  per escrow and recipient, what was paid or credited equals the fee rules applied
      cumulatively to the kernel's amounts, to the micro-USDC
  C2  conservation, with principal, bonds and credits kept apart, and every token transfer out
      of the vault explained exactly once
  C3  no refund-side fee unless the kernel logged DisputeOpened before the refund and the locked
      profile is BOTH_AFTER_DISPUTE
  C4  integrator refund fee <= protocol refund fee
  C5  vault solvency: balance = totalLocked + totalBonds + totalIntegratorCredit + protocolCredit
      + reported surplus
  C6  completeness in both directions between the run files, the kernel and the vault
  C7a locked terms equal the terms the run file requested
  C7b a finished entry that names an acceptance row has the columns of that row

Sources of an expected amount: the kernel's getTransaction, kernel events, the token's Transfer
logs, the run files, and the fee rules recomputed here with integer arithmetic. Never the vault's
quote functions, the vault's fee-split events or SDK output. Vault events are compared with the
result afterwards; the one vault-sourced input is the locked terms (IntegratorTermsLocked), which
must equal the run file's terms. On-chain views (remaining, bondBalances, credits, totals) are
read only as the right-hand side of the end-block equations.

How transfers are attributed: per transaction, the payments the kernel's events call for are
matched against the vault's outgoing transfers as a multiset of (recipient, amount). A fee that
has no matching transfer was credited. Whatever is left must be a credit withdrawal that the
outstanding credit covers; anything else is an unexplained transfer. A vault fee is pushed in
the vault call that pays the party, so its transfer lies between that payment and the kernel
event; an equal transfer to the same recipient elsewhere in the transaction is a withdrawal.
The result therefore does not depend on what else a transaction holds, on equal amounts going
to one recipient for different reasons, or on the order of the vault's own events. An incoming transfer that is
neither a deposit nor a bond is surplus: reported, never attributed, never a failure.

Python 3 standard library only; JSON-RPC reads only.
"""
import argparse
import glob
import json
import re
import sys
import urllib.request
from collections import Counter, defaultdict

MAX_BPS = 10_000
STATES = ["INITIATED", "QUOTED", "COMMITTED", "IN_PROGRESS", "DELIVERED", "SETTLED", "DISPUTED", "CANCELLED"]
TERMINAL = {"SETTLED", "CANCELLED"}
ZERO = "0x" + "00" * 20

# --------------------------------------------------------------------------- keccak256

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M64 = (1 << 64) - 1


def _rol(value, shift):
    return ((value << shift) | (value >> (64 - shift))) & _M64 if shift else value


def keccak256(data):
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate:
        padded.append(0)
    padded[-1] |= 0x80
    s = [[0] * 5 for _ in range(5)]
    for offset in range(0, len(padded), rate):
        for i in range(rate // 8):
            s[i % 5][i // 5] ^= int.from_bytes(padded[offset + 8 * i:offset + 8 * i + 8], "little")
        for rc in _RC:
            c = [s[x][0] ^ s[x][1] ^ s[x][2] ^ s[x][3] ^ s[x][4] for x in range(5)]
            d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
            s = [[s[x][y] ^ d[x] for y in range(5)] for x in range(5)]
            b = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    b[y][(2 * x + 3 * y) % 5] = _rol(s[x][y], _ROT[x][y])
            s = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & _M64 & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
            s[0][0] ^= rc
    return b"".join(s[i % 5][i // 5].to_bytes(8, "little") for i in range(4))


def topic(signature):
    return "0x" + keccak256(signature.encode()).hex()


def selector(signature):
    return "0x" + keccak256(signature.encode()).hex()[:8]


assert topic("Transfer(address,address,uint256)") == \
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", "keccak256 self-check"

T_TRANSFER = topic("Transfer(address,address,uint256)")
K_LINKED = topic("EscrowLinked(bytes32,address,bytes32,uint256,uint256)")
K_RELEASED = topic("EscrowReleased(bytes32,address,uint256,uint256)")
K_REFUNDED = topic("EscrowRefunded(bytes32,address,uint256,uint256)")
K_FEE = topic("PlatformFeeAccrued(bytes32,address,uint256,uint256)")
K_MEDIATOR = topic("EscrowMediatorPaid(bytes32,address,uint256,uint256)")
K_DISPUTE_OPENED = topic("DisputeOpened(bytes32,address,uint256,uint256)")
K_DISPUTE_RESOLVED = topic("DisputeResolved(bytes32,bytes32,address,bool,uint256,uint256)")
K_STATE = topic("StateTransitioned(bytes32,uint8,uint8,address,uint256)")
K_FEE_RECIPIENT = topic("FeeRecipientUpdated(address,address)")
K_ARCHIVE_FAILED = topic("ArchiveTreasuryFailed(bytes32,uint256,bytes)")
K_ARCHIVE_MISMATCH = topic("ArchivePayoutMismatch(bytes32,uint256,uint256)")
K_FEE_LEG_END = {K_FEE, K_ARCHIVE_FAILED, K_ARCHIVE_MISMATCH}
V_CREATED = topic("EscrowCreated(bytes32,address,address,uint256)")
V_TERMS = topic("IntegratorTermsLocked(bytes32,address,address,uint16,uint8)")
V_PROVIDER_SPLIT = topic("IntegratorFeeSplit(bytes32,address,address,uint256,uint256,uint256,bool)")
V_REFUND_SPLIT = topic("RefundFeeSplit(bytes32,address,address,uint256,uint256,uint256,uint256,bool,bool)")

# --------------------------------------------------------------------------- acceptance table
# (row, profile, variant) -> requester, provider, platform, kernel fee, vault protocol fee,
# mediator, terminal state. Micro-USDC. Bonds and credit withdrawals are excluded; a credited fee
# counts for its recipient (rows A15 and A16). "*" = the row has one value for both profiles.
U = 1_000_000


def _row(requester, provider, platform, kernel_fee, vault_fee, mediator, outcome):
    return {"requester": requester, "provider": provider, "platform": platform, "kernelFee": kernel_fee,
            "vaultProtocolFee": vault_fee, "mediator": mediator, "outcome": outcome}


SETTLE_1000 = _row(0, 980 * U, 10 * U, 10 * U, 0, 0, "SETTLED")
WIN_B_1000 = _row(980 * U, 0, 10 * U, 0, 10 * U, 0, "SETTLED")
ROWS = {
    ("A1", "-", ""): _row(0, 990 * U, 0, 10 * U, 0, 0, "SETTLED"),
    ("A2", "-", ""): _row(0, 990 * U, 0, 10 * U, 0, 0, "SETTLED"),
    ("A3", "*", ""): SETTLE_1000,
    ("A4", "*", ""): SETTLE_1000,
    ("A5", "*", ""): SETTLE_1000,
    ("A6", "D", ""): _row(500 * U, 490 * U, 5 * U, 5 * U, 0, 0, "CANCELLED"),
    ("A6", "B", ""): _row(490 * U, 490 * U, 10 * U, 5 * U, 5 * U, 0, "CANCELLED"),
    ("A7", "D", ""): _row(600 * U, 392 * U, 4 * U, 4 * U, 0, 0, "CANCELLED"),
    ("A7", "B", ""): _row(588 * U, 392 * U, 10 * U, 4 * U, 6 * U, 0, "CANCELLED"),
    ("A8", "*", ""): SETTLE_1000,
    ("A9", "D", ""): _row(1000 * U, 0, 0, 0, 0, 0, "SETTLED"),
    ("A9", "B", ""): WIN_B_1000,
    ("A10", "D", ""): _row(999_999_901, 980_000_098, 10_000_001, 10 * U, 0, 0, "SETTLED"),
    ("A10", "B", ""): _row(979_999_903, 980_000_098, 20 * U, 10 * U, 9_999_999, 0, "SETTLED"),
    ("A11", "*", ""): _row(1000 * U, 0, 0, 0, 0, 0, "CANCELLED"),
    ("A12", "*", ""): _row(950 * U, 49 * U, 500_000, 500_000, 0, 0, "CANCELLED"),
    ("A13", "*", ""): _row(1000 * U, 0, 0, 0, 0, 0, "CANCELLED"),
    ("A14", "D", ""): _row(900 * U, 0, 0, 0, 0, 100 * U, "SETTLED"),
    ("A14", "B", ""): _row(882 * U, 0, 9 * U, 0, 9 * U, 100 * U, "SETTLED"),
    ("A15", "*", "settle"): SETTLE_1000,
    ("A15", "B", "win"): WIN_B_1000,
    ("A16", "B", ""): WIN_B_1000,
    ("A18", "*", "settle"): _row(0, 970 * U, 20 * U, 10 * U, 0, 0, "SETTLED"),
    ("A18", "B", "win"): WIN_B_1000,
    ("A19", "*", "settle"): _row(0, 940_405, 9_595, 50_000, 0, 0, "SETTLED"),
    ("A19", "D", "win"): _row(U, 0, 0, 0, 0, 0, "SETTLED"),
    ("A19", "B", "win"): _row(980_000, 0, 10_000, 0, 10_000, 0, "SETTLED"),
    ("A20", "*", ""): _row(0, 4_900_000, 50_000, 50_000, 0, 0, "SETTLED"),
    ("A21", "*", "settle"): _row(0, 49_495, 505, 50_000, 0, 0, "SETTLED"),
    ("A21", "B", "win"): _row(98_000, 0, 1_000, 0, 1_000, 0, "SETTLED"),
    ("A22", "*", ""): _row(0, 0, 0, 50_000, 0, 0, "SETTLED"),
    ("A24", "B", ""): WIN_B_1000,
    ("A25", "B", ""): _row(490 * U, 445 * U, 55 * U, 5 * U, 5 * U, 0, "CANCELLED"),
}


def table_row(row, profile, variant):
    return ROWS.get((row, profile, variant)) or (ROWS.get((row, "*", variant)) if profile in ("D", "B") else None)


# --------------------------------------------------------------------------- JSON-RPC

class Rpc:
    def __init__(self, url):
        self.url = url
        self.count = 0

    def call(self, method, params):
        self.count += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.count, "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            answer = json.loads(response.read())
        if "error" in answer:
            raise RuntimeError(f"{method}: {answer['error']}")
        return answer["result"]

    def logs(self, address, topics, start, end, span=5000):
        """Logs of one address in [start, end], in chain order. The range is split on any error."""
        out, lo = [], start
        while lo <= end:
            hi = min(end, lo + span - 1)
            try:
                out.extend(self.call("eth_getLogs", [{"address": address, "topics": topics,
                                                      "fromBlock": hex(lo), "toBlock": hex(hi)}]))
                lo = hi + 1
            except (RuntimeError, OSError):
                if span == 1:
                    raise
                span = max(1, span // 2)
        return out

    def view(self, to, data, block):
        return self.call("eth_call", [{"to": to, "data": data}, hex(block)])


def word(data, index):
    return int(data[2 + 64 * index:66 + 64 * index], 16)


def address_of(value):
    return "0x" + value[-40:].lower()


def arg(value):
    return value[2:].lower().rjust(64, "0")


def order(log):
    return (int(log["blockNumber"], 16), int(log["transactionIndex"], 16), int(log["logIndex"], 16))


# --------------------------------------------------------------------------- reconciliation

class Escrow:
    """One escrow in scope: an escrow of the FeeSplitVault, or a plain-vault escrow a run file names."""

    def __init__(self, tx_id, vault, escrow_id, amount):
        self.tx_id, self.vault, self.escrow_id, self.amount = tx_id, vault, escrow_id, amount
        self.entry = None          # manifest entry, if a run file names it
        self.view = None           # kernel transaction view at the end block
        self.terms = None          # (integrator, bps, profile) from IntegratorTermsLocked
        self.applies = False       # terms bind to the transaction whose id is the escrow id
        self.protocol_bps = 0
        self.disputed = False      # the kernel logged DisputeOpened
        self.created = False       # the vault logged EscrowCreated
        self.net = self.refund = 0             # cumulative N and post-dispute R
        self.integrator_provider = 0           # integrator share taken on the provider side
        self.protocol_refund = self.integrator_refund = 0
        self.released = self.refunded = 0      # kernel totals
        self.columns = defaultdict(int)        # requester, provider, platform, kernelFee, ...
        self.credited = defaultdict(int)       # platform, vaultProtocolFee
        self.bond_in = self.bond_out = 0
        self.failures = []

    def fail(self, check, detail):
        self.failures.append({"check": check, "detail": detail})


class Reconciler:
    def __init__(self, rpc, args):
        self.rpc, self.args = rpc, args
        self.kernel = args.kernel.lower()
        self.vault = args.vault.lower()
        self.plain = args.plain_vault.lower()
        self.token = args.token.lower()
        self.start = args.from_block
        self.end = args.to_block if args.to_block is not None else int(rpc.call("eth_blockNumber", []), 16)
        self.escrows = {}                     # txId -> Escrow
        self.by_escrow_id = {}                # (vault, escrowId) -> Escrow
        self.global_failures = []
        self.surplus = []
        self.credit = defaultdict(int)        # integrator -> outstanding credit by this accounting
        self.protocol_credit = 0
        self.withdrawals = []
        self.ambiguous = []                   # withdrawals either credit pool could have paid
        self.dedicated = set()                # requesters dedicated to the scripts, named with --requester
        for address in args.requester:
            if not re.fullmatch(r"0x[0-9a-fA-F]{40}", address):
                raise SystemExit(f"--requester is not an address: {address}")
            self.dedicated.add(address.lower())
        self.manifest = []
        self.evidence_files = []
        self.plain_other = 0

    def fail(self, check, detail):
        self.global_failures.append({"check": check, "detail": detail})

    # ----- inputs -----

    def load_runs(self):
        paths = set()
        for pattern in self.args.runs:
            matched = glob.glob(pattern)
            if not matched:
                self.fail("C6", f"--runs pattern matches no file: {pattern}")
            paths.update(matched)
        paths = sorted(paths)
        seen = {}
        for path in paths:
            data = json.load(open(path))
            if data.get("kind") != "run":
                self.evidence_files.append({"file": path, "kind": data.get("kind", "unknown")})
                continue
            same = (data["kernel"].lower() == self.kernel and data["feeSplitVault"].lower() == self.vault
                    and data["plainVault"].lower() == self.plain and data["token"].lower() == self.token)
            if not same:
                self.fail("C6", f"run file is for another stack: {path}")
                continue
            for entry in data["entries"]:
                entry = dict(entry, file=path, txId=entry["txId"].lower(), vault=entry["vault"].lower(),
                             requester=entry["requester"].lower(), provider=entry["provider"].lower(),
                             integrator=entry["integrator"].lower())
                if entry["txId"] in seen:
                    self.fail("C6", f"transaction named twice: {entry['label']} and {seen[entry['txId']]}")
                    continue
                seen[entry["txId"]] = entry["label"]
                self.manifest.append(entry)
        self.run_files = [p for p in paths if p not in {e["file"] for e in self.evidence_files}]
        if not self.manifest:
            self.fail("C6", "the run files name no escrow: there is no manifest to reconcile against")

    def fetch(self):
        self.kernel_logs = sorted(self.rpc.logs(self.kernel, [], self.start, self.end), key=order)
        self.vault_logs = sorted(self.rpc.logs(self.vault, [], self.start, self.end), key=order)
        self.plain_created = self.rpc.logs(self.plain, [[V_CREATED]], self.start, self.end)
        self.transfers = {}
        for vault in (self.vault, self.plain):
            pad = "0x" + arg(vault)
            outgoing = self.rpc.logs(self.token, [[T_TRANSFER], [pad]], self.start, self.end)
            incoming = self.rpc.logs(self.token, [[T_TRANSFER], None, [pad]], self.start, self.end)
            # A transfer from the vault to itself matches both queries: keep one copy of each log.
            unique = {order(log): log for log in outgoing + incoming}
            self.transfers[vault] = [unique[position] for position in sorted(unique)]

    def kernel_view(self, tx_id):
        try:
            data = self.rpc.view(self.kernel, selector("getTransaction(bytes32)") + arg(tx_id), self.end)
        except RuntimeError:
            return None
        if len(data) < 2 + 64 * 21:
            return None
        return {"requester": address_of(data[2 + 64:2 + 128]), "provider": address_of(data[2 + 128:2 + 192]),
                "state": STATES[word(data, 3)], "amount": word(data, 4),
                "escrowContract": address_of(data[2 + 64 * 9:2 + 64 * 10]),
                "escrowId": "0x" + data[2 + 64 * 10:2 + 64 * 11], "protocolBps": word(data, 14)}

    def uint_view(self, to, signature, *params):
        return int(self.rpc.view(to, selector(signature) + "".join(arg(p) for p in params), self.end), 16)

    # ----- scope -----

    def build_scope(self):
        manifest = {e["txId"]: e for e in self.manifest}
        linked = {}
        for log in self.kernel_logs:
            if log["topics"][0] != K_LINKED:
                continue
            tx_id = log["topics"][1].lower()
            vault = address_of(log["data"][2:66])
            escrow_id = "0x" + log["data"][66:130]
            linked[tx_id] = (vault, escrow_id, word(log["data"], 2))
        for tx_id, (vault, escrow_id, amount) in linked.items():
            if vault == self.vault or (vault == self.plain and tx_id in manifest):
                escrow = Escrow(tx_id, vault, escrow_id, amount)
                escrow.entry = manifest.get(tx_id)
                self.escrows[tx_id] = escrow
                self.by_escrow_id[(vault, escrow_id)] = escrow
            elif vault == self.plain:
                self.plain_other += 1

        # C6: every manifest entry has its kernel link, in the vault the run file names.
        for entry in self.manifest:
            escrow = self.escrows.get(entry["txId"])
            if escrow is None:
                where = linked.get(entry["txId"])
                detail = "no kernel EscrowLinked in the block range" if where is None else f"linked to {where[0]}"
                self.fail("C6", f"manifest entry {entry['label']} ({entry['txId']}): {detail}")
            elif escrow.vault != entry["vault"]:
                escrow.fail("C6", f"linked to {escrow.vault}, the run file names {entry['vault']}")

        # Vault EscrowCreated, both directions, and the actor rule.
        actors = {e["requester"] for e in self.manifest} | self.dedicated
        created = [(self.vault, log) for log in self.vault_logs if log["topics"][0] == V_CREATED]
        created += [(self.plain, log) for log in self.plain_created]
        for vault, log in created:
            escrow_id = log["topics"][1].lower()
            requester = address_of(log["topics"][2])
            escrow = self.by_escrow_id.get((vault, escrow_id))
            if escrow is not None:
                escrow.created = True
            elif vault == self.vault:
                self.fail("C6", f"vault EscrowCreated {escrow_id} belongs to no kernel EscrowLinked")
            if requester in actors and (escrow is None or escrow.entry is None):
                self.fail("C6", f"escrow {escrow_id} of script requester {requester} in {vault} is named by no run file")
        for escrow in self.escrows.values():
            if not escrow.created:
                escrow.fail("C6", "the vault logged no EscrowCreated for this escrow")

        # Kernel views, locked terms and binding.
        for log in self.vault_logs:
            if log["topics"][0] == V_TERMS:
                escrow = self.by_escrow_id.get((self.vault, log["topics"][1].lower()))
                if escrow is not None:
                    escrow.terms = (address_of(log["topics"][3]), word(log["data"], 0), "B" if word(log["data"], 1) else "D")
        for escrow in self.escrows.values():
            escrow.view = self.kernel_view(escrow.tx_id)
            if escrow.view is None:
                escrow.fail("C6", "kernel.getTransaction failed")
                continue
            if escrow.view["amount"] != escrow.amount:
                escrow.fail("C6", "kernel amount differs from the linked amount")
            if escrow.terms is None:
                continue
            # Rule of plan 2.4: terms apply only when the transaction whose id is the escrow id is
            # linked to this vault under that id with the same parties.
            named = escrow.view if escrow.escrow_id == escrow.tx_id else self.kernel_view(escrow.escrow_id)
            escrow.applies = bool(
                named and named["escrowContract"] == self.vault and named["escrowId"] == escrow.escrow_id
                and named["requester"] == escrow.view["requester"] and named["provider"] == escrow.view["provider"]
                and 0 < named["protocolBps"] <= 500)
            escrow.protocol_bps = named["protocolBps"] if escrow.applies else 0

    # ----- fee rules, recomputed -----

    def provider_cut(self, escrow, amount):
        if not escrow.applies:
            return 0
        _, bps, _ = escrow.terms
        target = min((escrow.net + amount) * bps // (MAX_BPS - escrow.protocol_bps), escrow.amount * bps // MAX_BPS)
        cut = target - escrow.integrator_provider
        escrow.integrator_provider = target
        return cut

    def refund_fees(self, escrow, amount):
        if not (escrow.applies and escrow.terms[2] == "B" and escrow.disputed):
            return 0, 0
        _, bps, _ = escrow.terms
        total = escrow.refund + amount
        protocol = total * escrow.protocol_bps // MAX_BPS - escrow.protocol_refund
        integrator = total * min(bps, escrow.protocol_bps) // MAX_BPS - escrow.integrator_refund
        if protocol + integrator > amount:      # a refund too small to carry both steps
            excess = protocol + integrator - amount
            from_integrator = min(excess, integrator)
            integrator -= from_integrator
            protocol -= excess - from_integrator
        escrow.refund = total
        escrow.protocol_refund += protocol
        escrow.integrator_refund += integrator
        return protocol, integrator

    # ----- replay -----

    def fee_recipient_timeline(self):
        """kernel.feeRecipient() over the range, from the end-block value and the kernel's events."""
        current = address_of(self.rpc.view(self.kernel, selector("feeRecipient()"), self.end))
        changes = [(order(l), address_of(l["topics"][1]), address_of(l["topics"][2]))
                   for l in self.kernel_logs if l["topics"][0] == K_FEE_RECIPIENT]
        self.fee_changes = changes
        self.fee_recipient_start = changes[0][1] if changes else current

    def fee_recipient_at(self, position):
        recipient = self.fee_recipient_start
        for at, _, new in self.fee_changes:
            if at < position:
                recipient = new
        return recipient

    def replay(self):
        self.fee_recipient_timeline()
        by_tx = defaultdict(lambda: {"kernel": [], "transfers": {self.vault: [], self.plain: []}})
        for log in self.kernel_logs:
            by_tx[log["transactionHash"]]["kernel"].append(log)
        for vault, logs in self.transfers.items():
            for log in logs:
                by_tx[log["transactionHash"]]["transfers"][vault].append(log)
        positions = {}
        for tx_hash, group in by_tx.items():
            logs = group["kernel"] + group["transfers"][self.vault] + group["transfers"][self.plain]
            positions[tx_hash] = min(order(l) for l in logs)
        for tx_hash in sorted(by_tx, key=lambda h: positions[h]):
            for vault in (self.vault, self.plain):
                self.replay_tx(tx_hash, vault, by_tx[tx_hash])

    def replay_tx(self, tx_hash, vault, group):
        strict = vault == self.vault          # every transfer of the FeeSplitVault must be explained
        transfers = group["transfers"][vault]
        outgoing = []                         # [position, recipient, amount], removed when explained
        incoming = Counter()
        for log in transfers:
            sender, recipient, value = address_of(log["topics"][1]), address_of(log["topics"][2]), int(log["data"], 16)
            if value == 0:
                continue
            if sender == vault:
                outgoing.append([order(log), recipient, value])
            if recipient == vault:
                # Includes a payment the vault made to itself (anyone may name the vault as provider):
                # the tokens stay, and once the payment is explained they are surplus.
                incoming[(sender, value)] += 1

        def take(recipient, amount, before, after=None):
            """Remove one transfer of `amount` to `recipient` and return its position, else None.
            A kernel-declared payment takes the last such transfer before the kernel event that
            declares it, else any: equal transfers are interchangeable, so the choice changes no
            total. A vault fee whose payout moved money (`after` = that transfer) is pushed inside
            the same vault call, so only a transfer between the payout and the kernel event is its
            push; an equal transfer elsewhere in the transaction is a credit withdrawal."""
            matches = [t for t in outgoing if t[1] == recipient and t[2] == amount]
            if after is not None:
                matches = [t for t in matches if after < t[0] < before]
                chosen = min(matches) if matches else None
            else:
                earlier = [t for t in matches if t[0] < before]
                chosen = max(earlier) if earlier else (min(matches) if matches else None)
            if chosen is None:
                return None
            outgoing.remove(chosen)
            return chosen[0]

        definite = []      # (escrow, check, recipient, amount, description, position of the kernel event)
        soft = []          # (escrow, column, recipient, amount, position): pushed, or credited when unmatched
        deposits = []      # (escrow, sender, amount, description)
        touched = []
        for log in group["kernel"]:
            kind = log["topics"][0]
            escrow = self.escrows.get(log["topics"][1].lower()) if len(log["topics"]) > 1 else None
            if escrow is None or escrow.vault != vault or escrow.view is None:
                continue
            if escrow not in touched:
                touched.append(escrow)
            data = log["data"]
            if kind == K_LINKED:
                deposits.append((escrow, escrow.view["requester"], escrow.amount, "deposit"))
            elif kind == K_DISPUTE_OPENED:
                escrow.disputed = True
                bond = word(data, 0)
                escrow.bond_in += bond
                deposits.append((escrow, address_of(log["topics"][2]), bond, "dispute bond"))
            elif kind == K_RELEASED:
                amount = word(data, 1)
                cut = self.provider_cut(escrow, amount)
                escrow.net += amount
                escrow.released += amount
                escrow.columns["provider"] += amount - cut
                escrow.columns["platform"] += cut
                definite.append((escrow, "C1", address_of(data[2:66]), amount - cut, "provider payout", order(log)))
                if cut:
                    soft.append((escrow, "platform", escrow.terms[0], cut, order(log)))
            elif kind == K_REFUNDED:
                amount = word(data, 1)
                protocol, integrator = self.refund_fees(escrow, amount)
                escrow.refunded += amount
                escrow.columns["requester"] += amount - protocol - integrator
                escrow.columns["vaultProtocolFee"] += protocol
                escrow.columns["platform"] += integrator
                check = "C1" if protocol + integrator else "C3"     # a fee-free refund must arrive whole
                definite.append((escrow, check, address_of(data[2:66]), amount - protocol - integrator, "refund", order(log)))
                if protocol:
                    soft.append((escrow, "vaultProtocolFee", self.fee_recipient_at(order(log)), protocol, order(log)))
                if integrator:
                    soft.append((escrow, "platform", escrow.terms[0], integrator, order(log)))
            elif kind == K_FEE:
                amount = word(data, 0)
                escrow.columns["kernelFee"] += amount
                definite.append((escrow, "C1", address_of(log["topics"][2]), amount, "kernel fee", order(log)))
            elif kind == K_MEDIATOR:
                amount = word(data, 0)
                escrow.columns["mediator"] += amount
                definite.append((escrow, "C1", address_of(log["topics"][2]), amount, "mediator payout", order(log)))
            elif kind == K_DISPUTE_RESOLVED:
                bond = word(data, 1)
                escrow.bond_out += bond
                # Bond: to the winner on SETTLED, back to the initiator on CANCELLED.
                state = self.state_after(group["kernel"], log)
                if state == "CANCELLED":
                    recipient = address_of(log["topics"][3])
                else:
                    recipient = escrow.view["requester"] if word(data, 0) else escrow.view["provider"]
                definite.append((escrow, "C2", recipient, bond, "bond release", order(log)))

        paid_at = {}       # position of a kernel event -> position of the transfer it declared
        for escrow, check, recipient, amount, what, position in definite:
            if not amount:
                continue
            paid_at[position] = take(recipient, amount, position)
            if paid_at[position] is None:
                escrow.fail(check, f"{what}: no transfer of {amount} to {recipient} in {tx_hash}")
        credited = []      # fees with no matching transfer: (escrow, column, recipient, amount)
        for escrow, column, recipient, amount, position in soft:
            if take(recipient, amount, position, paid_at.get(position)) is not None:
                continue
            credited.append((escrow, column, recipient, amount))
            escrow.credited[column] += amount
            if column == "platform":
                self.credit[recipient] += amount
            else:
                self.protocol_credit += amount

        # The archive share of a kernel fee has no event of its own: it is a transfer to the kernel
        # that no kernel-declared payment claimed, and it belongs to the transaction the kernel's next
        # fee event names. (The kernel can also be a provider; that payment was matched above.)
        fee_ends = [(order(l), l["topics"][1].lower()) for l in group["kernel"] if l["topics"][0] in K_FEE_LEG_END]
        for transfer in [t for t in outgoing if t[1] == self.kernel]:
            at, _, value = transfer
            owner = next((self.escrows.get(tx_id) for position, tx_id in fee_ends if position > at), None)
            if owner is not None and owner.vault == vault:
                owner.columns["kernelFee"] += value
                outgoing.remove(transfer)

        for escrow, sender, amount, what in deposits:
            if incoming[(sender, amount)] > 0:
                incoming[(sender, amount)] -= 1
            else:
                escrow.fail("C2", f"{what}: no transfer of {amount} from {sender} in {tx_hash}")

        if not strict:
            return
        # What is left must be a credit withdrawal covered by the outstanding credit, counting the
        # credits this transaction accrued. Only then is a leftover an unexplained transfer; and only
        # then does a fee that found no transfer of its own amount count as paid in a wrong amount.
        for position, recipient, amount in sorted(outgoing):
            integrator_pool = self.credit.get(recipient, 0) >= amount
            protocol_pool = self.protocol_credit >= amount and recipient == self.fee_recipient_at(position)
            if integrator_pool and protocol_pool:
                # The integrator is also the fee recipient and both pools cover the transfer: which
                # one was withdrawn is settled against the end-block credits in finish().
                withdrawal = {"tx": tx_hash, "kind": "ambiguous", "to": recipient, "amount": amount}
                self.withdrawals.append(withdrawal)
                self.ambiguous.append(withdrawal)
            elif integrator_pool:
                self.credit[recipient] -= amount
                self.withdrawals.append({"tx": tx_hash, "kind": "integrator", "to": recipient, "amount": amount})
            elif protocol_pool:
                self.protocol_credit -= amount
                self.withdrawals.append({"tx": tx_hash, "kind": "protocol", "to": recipient, "amount": amount})
            else:
                self.fail("C2", f"unexplained transfer of {amount} to {recipient} in {tx_hash}")
                for escrow in touched:
                    escrow.fail("C2", f"unexplained transfer of {amount} to {recipient} in {tx_hash}")
                for escrow, column, to, expected in credited:
                    if to == recipient:
                        escrow.fail("C1", f"{column}: expected {expected} to {recipient}, {amount} was transferred in {tx_hash}")
        for (sender, amount), n in sorted(incoming.items()):
            for _ in range(n):
                self.surplus.append({"tx": tx_hash, "from": sender, "amount": amount})

    def state_after(self, kernel_logs, resolved):
        """State the transaction entered in the same kernel call that released the bond."""
        tx_id = resolved["topics"][1]
        state = None
        for log in kernel_logs:
            if log["topics"][0] == K_STATE and log["topics"][1] == tx_id and order(log) < order(resolved):
                state = STATES[int(log["topics"][3], 16)]
        return state

    # ----- end-block equations and verdicts -----

    def finish(self):
        integrators = set(self.credit)
        for escrow in self.escrows.values():
            if escrow.view is None:
                continue
            if escrow.terms:
                integrators.add(escrow.terms[0])
            remaining = self.uint_view(escrow.vault, "remaining(bytes32)", escrow.escrow_id)
            paid = escrow.released + escrow.refunded + escrow.columns["kernelFee"] + escrow.columns["mediator"]
            if escrow.amount != paid + remaining:
                escrow.fail("C2", f"deposit {escrow.amount} != paid out {paid} + remaining {remaining}")
            bond = self.uint_view(escrow.vault, "bondBalances(bytes32)", escrow.escrow_id)
            if escrow.bond_in != escrow.bond_out + bond:
                escrow.fail("C2", f"bond in {escrow.bond_in} != bond out {escrow.bond_out} + held {bond}")
            if escrow.integrator_refund > escrow.protocol_refund:
                escrow.fail("C4", "integrator refund fee above the protocol refund fee")
            escrow.remaining = remaining
            self.check_terms(escrow)
        self.check_vault_events()

        # A withdrawal both pools covered came from the integrator pool exactly when that pool, by
        # this accounting, is above its on-chain value by at least the amount; else from the protocol.
        for withdrawal in self.ambiguous:
            recipient, amount = withdrawal["to"], withdrawal["amount"]
            on_chain = self.uint_view(self.vault, "integratorCredit(address)", recipient)
            if self.credit.get(recipient, 0) - on_chain >= amount:
                self.credit[recipient] -= amount
                withdrawal["kind"] = "integrator"
            else:
                self.protocol_credit -= amount
                withdrawal["kind"] = "protocol"

        for integrator in sorted(integrators):
            on_chain = self.uint_view(self.vault, "integratorCredit(address)", integrator)
            if on_chain != self.credit.get(integrator, 0):
                self.fail("C2", f"integrator credit of {integrator}: accrued - withdrawn = "
                                f"{self.credit.get(integrator, 0)}, on chain {on_chain}")
        on_chain = self.uint_view(self.vault, "protocolCredit()")
        if on_chain != self.protocol_credit:
            self.fail("C2", f"protocol credit: accrued - withdrawn = {self.protocol_credit}, on chain {on_chain}")

        balance = self.uint_view(self.token, "balanceOf(address)", self.vault)
        owed = sum(self.uint_view(self.vault, s) for s in
                   ("totalLocked()", "totalBonds()", "totalIntegratorCredit()", "protocolCredit()"))
        surplus = sum(s["amount"] for s in self.surplus)
        self.solvency = {"balance": balance, "owed": owed, "surplus": surplus}
        if balance != owed + surplus:
            self.fail("C5", f"vault balance {balance} != counters {owed} + surplus {surplus}")

    def check_terms(self, escrow):
        entry = escrow.entry
        if entry is None:
            return
        if entry["profile"] == "-":
            if escrow.terms is not None:
                escrow.fail("C7a", f"the run file requested no terms, locked {escrow.terms}")
        else:
            requested = (entry["integrator"], entry["bps"], entry["profile"])
            if escrow.terms != requested:
                escrow.fail("C7a", f"requested terms {requested}, locked {escrow.terms}")
        if entry["requester"] != escrow.view["requester"] or entry["provider"] != escrow.view["provider"] \
                or entry["amount"] != escrow.amount:
            escrow.fail("C7a", "parties or amount differ from the run file")
        if entry["row"] and escrow.view["state"] in TERMINAL:
            row = table_row(entry["row"], entry["profile"], entry.get("variant", ""))
            if row is None:
                escrow.fail("C7b", f"no acceptance row {entry['row']} / {entry['profile']} / {entry.get('variant', '')}")
                return
            if escrow.view["state"] != row["outcome"]:
                escrow.fail("C7b", f"terminal state {escrow.view['state']}, the row names {row['outcome']}")
            for column in ("requester", "provider", "platform", "kernelFee", "vaultProtocolFee", "mediator"):
                if escrow.columns[column] != row[column]:
                    escrow.fail("C7b", f"{column}: {escrow.columns[column]}, the row has {row[column]}")

    def check_vault_events(self):
        """The vault's own fee-split events, compared with the result; never a source of it."""
        provider_side = defaultdict(int)
        refund_side = defaultdict(lambda: [0, 0])
        for log in self.vault_logs:
            escrow = self.by_escrow_id.get((self.vault, log["topics"][1].lower())) if len(log["topics"]) > 1 else None
            if escrow is None:
                continue
            if log["topics"][0] == V_PROVIDER_SPLIT:
                provider_side[escrow.tx_id] += word(log["data"], 2)
            elif log["topics"][0] == V_REFUND_SPLIT:
                refund_side[escrow.tx_id][0] += word(log["data"], 2)
                refund_side[escrow.tx_id][1] += word(log["data"], 3)
                if not escrow.disputed and word(log["data"], 2) + word(log["data"], 3):
                    escrow.fail("C3", "the vault logged a refund fee on an escrow the kernel never disputed")
        for escrow in self.escrows.values():
            if escrow.vault != self.vault:
                continue
            if provider_side[escrow.tx_id] != escrow.integrator_provider:
                escrow.fail("C1", f"vault IntegratorFeeSplit total {provider_side[escrow.tx_id]}, "
                                  f"the rule gives {escrow.integrator_provider}")
            if refund_side[escrow.tx_id] != [escrow.protocol_refund, escrow.integrator_refund]:
                escrow.fail("C1", f"vault RefundFeeSplit totals {refund_side[escrow.tx_id]}, the rule gives "
                                  f"{[escrow.protocol_refund, escrow.integrator_refund]}")

    def report(self):
        entries = []
        for escrow in sorted(self.escrows.values(), key=lambda e: (e.entry is None, (e.entry or {}).get("label", ""), e.tx_id)):
            state = escrow.view["state"] if escrow.view else "UNKNOWN"
            status = "fail" if escrow.failures else ("pass" if state in TERMINAL else "pending")
            entries.append({
                "label": escrow.entry["label"] if escrow.entry else None,
                "scope": "manifest" if escrow.entry else "foreign",
                "row": (escrow.entry or {}).get("row", ""), "profile": (escrow.entry or {}).get("profile", ""),
                "txId": escrow.tx_id, "vault": "plain" if escrow.vault == self.plain else "feeSplit",
                "state": state, "status": status, "amount": escrow.amount,
                "columns": {k: escrow.columns[k] for k in
                            ("requester", "provider", "platform", "kernelFee", "vaultProtocolFee", "mediator")},
                "credited": dict(escrow.credited), "remaining": getattr(escrow, "remaining", None),
                "failures": escrow.failures,
            })
        named = {e["txId"] for e in self.manifest}
        for entry in self.manifest:          # manifest entries without an escrow in scope
            if entry["txId"] not in self.escrows:
                entries.append({"label": entry["label"], "scope": "manifest", "row": entry["row"],
                                "profile": entry["profile"], "txId": entry["txId"], "vault": None, "state": "UNKNOWN",
                                "status": "fail", "amount": entry["amount"], "columns": {}, "credited": {},
                                "remaining": None,
                                "failures": [{"check": "C6", "detail": "no kernel link in the block range"}]})
        allowed = set(self.args.allow_pending or [])
        incomplete = [e["label"] for e in entries
                      if e["scope"] == "manifest" and e["status"] == "pending" and e["label"] not in allowed]
        counts = Counter(e["status"] for e in entries)
        failed = counts["fail"] > 0 or bool(self.global_failures)
        complete_failed = bool(self.args.require_complete and incomplete)
        return {
            "kernel": self.kernel, "vault": self.vault, "plainVault": self.plain, "token": self.token,
            "fromBlock": self.start, "toBlock": self.end, "runFiles": self.run_files,
            "evidenceFiles": self.evidence_files,
            "counts": {"pass": counts["pass"], "pending": counts["pending"], "fail": counts["fail"],
                       "manifest": sum(e["scope"] == "manifest" for e in entries),
                       "foreign": sum(e["scope"] == "foreign" for e in entries),
                       "plainVaultOtherEscrows": self.plain_other, "manifestNamed": len(named)},
            "surplus": {"total": sum(s["amount"] for s in self.surplus), "transfers": self.surplus},
            "solvency": self.solvency, "withdrawals": self.withdrawals,
            "credits": {"integrators": {k: v for k, v in self.credit.items() if v}, "protocol": self.protocol_credit},
            "globalFailures": self.global_failures, "incompleteManifestEntries": incomplete,
            "requireComplete": bool(self.args.require_complete), "allowPending": sorted(allowed),
            "dedicatedRequesters": sorted(self.dedicated),
            "entries": entries,
            "result": "fail" if failed else ("incomplete" if complete_failed else "pass"),
        }


def print_table(report):
    print(f"FeeSplitVault reconciliation  blocks {report['fromBlock']}-{report['toBlock']}  vault {report['vault']}")
    print(f"{'status':8} {'scope':9} {'label':26} {'state':11} {'requester':>13} {'provider':>13} {'platform':>11} "
          f"{'kernel fee':>11} {'vault fee':>11} {'mediator':>11}")
    for e in report["entries"]:
        c = e["columns"]
        cells = " ".join(f"{c.get(k, 0):>{w}}" for k, w in
                         (("requester", 13), ("provider", 13), ("platform", 11), ("kernelFee", 11),
                          ("vaultProtocolFee", 11), ("mediator", 11)))
        print(f"{e['status']:8} {e['scope']:9} {(e['label'] or e['txId'][:14]):26} {e['state']:11} {cells}")
        for failure in e["failures"]:
            print(f"         {failure['check']}: {failure['detail']}  [{e['txId']}]")
    for failure in report["globalFailures"]:
        print(f"fail     {failure['check']}: {failure['detail']}")
    n = report["counts"]
    print(f"pass {n['pass']}  pending {n['pending']}  fail {n['fail']}  foreign {n['foreign']}  "
          f"surplus {report['surplus']['total']}  result {report['result'].upper()}")
    if not report["dedicatedRequesters"]:
        print("note: no --requester given; an escrow of a script address is only missed here if a run file "
              "names that address")
    if report["incompleteManifestEntries"] and report["requireComplete"]:
        print("incomplete manifest entries: " + ", ".join(report["incompleteManifestEntries"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--vault", required=True, help="the FeeSplitVault")
    parser.add_argument("--plain-vault", required=True, help="the plain EscrowVault of the same kernel")
    parser.add_argument("--token", required=True)
    parser.add_argument("--from-block", type=int, required=True)
    parser.add_argument("--to-block", type=int)
    parser.add_argument("--runs", action="append", required=True, help="glob of run files; repeatable")
    parser.add_argument("--requester", action="append", default=[], metavar="ADDRESS",
                        help="a requester address dedicated to the acceptance scripts or the soak; repeatable. "
                             "An escrow of such an address that no run file names fails with C6. Without it "
                             "the dedicated addresses are only those the run files themselves name, so a "
                             "requester whose every entry is missing goes unnoticed")
    parser.add_argument("--require-complete", action="store_true",
                        help="also fail when a manifest entry is still open")
    parser.add_argument("--allow-pending", action="append", metavar="LABEL",
                        help="manifest entry allowed to be open under --require-complete; repeatable")
    parser.add_argument("--out", help="write the JSON report to this file")
    args = parser.parse_args()

    reconciler = Reconciler(Rpc(args.rpc), args)
    reconciler.load_runs()
    reconciler.fetch()
    reconciler.build_scope()
    reconciler.replay()
    reconciler.finish()
    report = reconciler.report()
    if args.out:
        with open(args.out, "w") as handle:
            json.dump(report, handle, indent=2)
            handle.write("\n")
    print_table(report)
    return 0 if report["result"] == "pass" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"reconcile_feesplit: {error}", file=sys.stderr)
        sys.exit(2)
