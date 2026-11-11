------------------------------- MODULE FeeSplit ------------------------------
EXTENDS Naturals, Integers, FiniteSets
CONSTANT Transactions, Deposit, Profile
VARIABLES remaining, debt, charged, active, disputed, netPaid, refunded,
          provider, requester, integratorP, intCreditP, integratorR, intCreditR,
          vaultProtocol, protCredit, feesOut,
          sProvider, sRequester, sFeesOut,
          intBlocked, feeBlocked
escrow == <<remaining, debt, charged, active, netPaid, refunded>>
paid == <<provider, requester, integratorP, intCreditP, integratorR, intCreditR,
          vaultProtocol, protCredit, feesOut>>
shadow == <<sProvider, sRequester, sFeesOut>>
blocks == <<intBlocked, feeBlocked>>
vars == <<escrow, disputed, paid, shadow, blocks>>

\* Abstract rates. Integrator on the provider side 1/3; protocol on a refund 1/4; the integrator on
\* a refund takes the smaller of its own rate and the protocol's (the larger divisor).
IntDiv == 3
ProtDiv == 4
RefundIntDiv == IF IntDiv > ProtDiv THEN IntDiv ELSE ProtDiv

Zero == [t \in Transactions |-> 0]
Principal(t) == remaining[t] - debt[t]

Init ==
    /\ remaining = [t \in Transactions |-> Deposit]
    /\ active = [t \in Transactions |-> TRUE]
    /\ disputed = [t \in Transactions |-> FALSE]
    /\ debt = Zero /\ charged = Zero /\ netPaid = Zero /\ refunded = Zero
    /\ provider = Zero /\ requester = Zero /\ integratorP = Zero /\ intCreditP = Zero
    /\ integratorR = Zero /\ intCreditR = Zero /\ vaultProtocol = Zero /\ protCredit = Zero
    /\ feesOut = Zero /\ sProvider = Zero /\ sRequester = Zero /\ sFeesOut = Zero
    /\ intBlocked = FALSE /\ feeBlocked = FALSE

\* One kernel exit step: gross `a` to the provider side, `r` refunded to the requester.
\* The kernel charges its one-unit fee once and reserves it while the fee recipient is blocked.
\* The vault splits the provider's net amount, and splits the refund only after a dispute in
\* profile Both. A blocked recipient is credited; nothing here can stop the step.
Move(t, a, r, terminal) ==
    LET fee == IF a > 0 /\ charged[t] = 0 THEN 1 ELSE 0
        net == a - fee
        cut == (netPaid[t] + net) \div IntDiv - netPaid[t] \div IntDiv
        removed == IF feeBlocked THEN 0 ELSE fee
        charge == Profile = "Both" /\ disputed[t]
        pf == IF charge THEN (refunded[t] + r) \div ProtDiv - refunded[t] \div ProtDiv ELSE 0
        rf == IF charge THEN (refunded[t] + r) \div RefundIntDiv - refunded[t] \div RefundIntDiv ELSE 0
    IN
    /\ remaining' = [remaining EXCEPT ![t] = @ - net - removed - r]
    /\ debt' = [debt EXCEPT ![t] = @ + fee - removed]
    /\ charged' = [charged EXCEPT ![t] = @ + fee]
    /\ netPaid' = [netPaid EXCEPT ![t] = @ + net]
    /\ refunded' = [refunded EXCEPT ![t] = @ + (IF disputed[t] THEN r ELSE 0)]
    /\ active' = [active EXCEPT ![t] = ~terminal]
    /\ provider' = [provider EXCEPT ![t] = @ + net - cut]
    /\ feesOut' = [feesOut EXCEPT ![t] = @ + removed]
    /\ integratorP' = [integratorP EXCEPT ![t] = @ + (IF intBlocked THEN 0 ELSE cut)]
    /\ intCreditP' = [intCreditP EXCEPT ![t] = @ + (IF intBlocked THEN cut ELSE 0)]
    /\ requester' = [requester EXCEPT ![t] = @ + r - pf - rf]
    /\ vaultProtocol' = [vaultProtocol EXCEPT ![t] = @ + (IF feeBlocked THEN 0 ELSE pf)]
    /\ protCredit' = [protCredit EXCEPT ![t] = @ + (IF feeBlocked THEN pf ELSE 0)]
    /\ integratorR' = [integratorR EXCEPT ![t] = @ + (IF intBlocked THEN 0 ELSE rf)]
    /\ intCreditR' = [intCreditR EXCEPT ![t] = @ + (IF intBlocked THEN rf ELSE 0)]
    /\ sProvider' = [sProvider EXCEPT ![t] = @ + net]
    /\ sRequester' = [sRequester EXCEPT ![t] = @ + r]
    /\ sFeesOut' = [sFeesOut EXCEPT ![t] = @ + removed]
    /\ UNCHANGED <<disputed, blocks>>

Milestone(t, a) == active[t] /\ ~disputed[t] /\ a \in 1..Principal(t) /\ Move(t, a, 0, FALSE)
Settlement(t) == active[t] /\ ~disputed[t] /\ Move(t, Principal(t), 0, TRUE)
\* Provider cancel and stalled recovery (a = 0), requester penalty cancel (a > 0): never disputed.
PreDisputeRefund(t, a) ==
    active[t] /\ ~disputed[t] /\ a \in 0..Principal(t) /\ Move(t, a, Principal(t) - a, TRUE)
OpenDispute(t) ==
    /\ active[t] /\ ~disputed[t]
    /\ disputed' = [disputed EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<escrow, paid, shadow, blocks>>
\* Any dispute outcome: `a` to the provider side, the rest refunded.
DisputeRefund(t, a) ==
    active[t] /\ disputed[t] /\ a \in 0..Principal(t) /\ Move(t, a, Principal(t) - a, TRUE)

RetryFee(t) ==
    /\ debt[t] > 0 /\ ~feeBlocked
    /\ remaining' = [remaining EXCEPT ![t] = @ - debt[t]]
    /\ feesOut' = [feesOut EXCEPT ![t] = @ + debt[t]]
    /\ sFeesOut' = [sFeesOut EXCEPT ![t] = @ + debt[t]]
    /\ debt' = [debt EXCEPT ![t] = 0]
    /\ UNCHANGED <<charged, active, netPaid, refunded, disputed, blocks, sProvider, sRequester,
                   provider, requester, integratorP, intCreditP, integratorR, intCreditR,
                   vaultProtocol, protCredit>>

ToggleBlocks ==
    /\ \E i, f \in BOOLEAN:
        /\ i # intBlocked \/ f # feeBlocked
        /\ intBlocked' = i /\ feeBlocked' = f
    /\ UNCHANGED <<escrow, disputed, paid, shadow>>

WithdrawIntegrator ==
    /\ ~intBlocked
    /\ \E t \in Transactions: intCreditP[t] + intCreditR[t] > 0
    /\ integratorP' = [t \in Transactions |-> integratorP[t] + intCreditP[t]]
    /\ integratorR' = [t \in Transactions |-> integratorR[t] + intCreditR[t]]
    /\ intCreditP' = Zero /\ intCreditR' = Zero
    /\ UNCHANGED <<escrow, disputed, shadow, blocks, provider, requester, vaultProtocol, protCredit, feesOut>>

WithdrawProtocol ==
    /\ ~feeBlocked
    /\ \E t \in Transactions: protCredit[t] > 0
    /\ vaultProtocol' = [t \in Transactions |-> vaultProtocol[t] + protCredit[t]]
    /\ protCredit' = Zero
    /\ UNCHANGED <<escrow, disputed, shadow, blocks, provider, requester, integratorP, intCreditP,
                   integratorR, intCreditR, feesOut>>

Next ==
    \/ \E t \in Transactions, a \in 1..Deposit: Milestone(t, a)
    \/ \E t \in Transactions: Settlement(t)
    \/ \E t \in Transactions: OpenDispute(t)
    \/ \E t \in Transactions, a \in 0..Deposit: DisputeRefund(t, a)
    \/ \E t \in Transactions, a \in 0..Deposit: PreDisputeRefund(t, a)
    \/ \E t \in Transactions: RetryFee(t)
    \/ ToggleBlocks
    \/ WithdrawIntegrator
    \/ WithdrawProtocol

ProtocolRefund(t) == vaultProtocol[t] + protCredit[t]
IntegratorRefund(t) == integratorR[t] + intCreditR[t]
IntegratorProvider(t) == integratorP[t] + intCreditP[t]

SplitConserved ==
    \A t \in Transactions:
        Deposit = provider[t] + IntegratorProvider(t) + requester[t] + ProtocolRefund(t)
                  + IntegratorRefund(t) + feesOut[t] + remaining[t]

\* A plain vault under the same kernel steps: the kernel fee is untouched, the integrator share
\* comes out of the provider's amount, and in profile Default the refunds are identical.
FeeNeutral ==
    \A t \in Transactions:
        /\ feesOut[t] = sFeesOut[t]
        /\ provider[t] + IntegratorProvider(t) = sProvider[t]
        /\ Profile = "Default" => requester[t] = sRequester[t]

RefundFeeOnlyAfterDispute ==
    \A t \in Transactions:
        ProtocolRefund(t) + IntegratorRefund(t) > 0 => Profile = "Both" /\ disputed[t]

\* Conservation is not correctness: the fees must also be the ones the rule names.
RefundFeesMatchRule ==
    \A t \in Transactions:
        IF Profile = "Both" /\ disputed[t]
        THEN /\ ProtocolRefund(t) = refunded[t] \div ProtDiv
             /\ IntegratorRefund(t) = refunded[t] \div RefundIntDiv
        ELSE ProtocolRefund(t) = 0 /\ IntegratorRefund(t) = 0

RefundSideCap == \A t \in Transactions: IntegratorRefund(t) <= ProtocolRefund(t)

RefundConserved ==
    Profile = "Both" =>
        \A t \in Transactions: requester[t] + ProtocolRefund(t) + IntegratorRefund(t) = sRequester[t]

Spec == Init /\ [][Next]_vars
=============================================================================
