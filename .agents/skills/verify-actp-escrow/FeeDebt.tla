------------------------------- MODULE FeeDebt ------------------------------
EXTENDS Naturals, Integers, FiniteSets
CONSTANT Transactions, Deposit
VARIABLES remaining, debt, charged, participants, feesOut, active
vars == <<remaining, debt, charged, participants, feesOut, active>>

Principal(t) == remaining[t] - debt[t]

Init ==
    /\ remaining = [t \in Transactions |-> Deposit]
    /\ debt = [t \in Transactions |-> 0]
    /\ charged = [t \in Transactions |-> 0]
    /\ participants = [t \in Transactions |-> 0]
    /\ feesOut = [t \in Transactions |-> 0]
    /\ active = [t \in Transactions |-> TRUE]

Payout(t, amount, succeeds, terminal) ==
    LET fee == IF charged[t] = 0 THEN 1 ELSE 0
        removed == IF succeeds THEN fee ELSE 0
    IN
    /\ active[t] /\ amount \in 1..Principal(t)
    /\ remaining' = [remaining EXCEPT ![t] = @ - (amount - fee) - removed]
    /\ debt' = [debt EXCEPT ![t] = @ + fee - removed]
    /\ charged' = [charged EXCEPT ![t] = @ + fee]
    /\ participants' = [participants EXCEPT ![t] = @ + amount - fee]
    /\ feesOut' = [feesOut EXCEPT ![t] = @ + removed]
    /\ active' = [active EXCEPT ![t] = ~terminal]

Milestone(t, amount, succeeds) == Payout(t, amount, succeeds, FALSE)
Settlement(t, succeeds) == Payout(t, Principal(t), succeeds, TRUE)

Refund(t) ==
    /\ active[t]
    /\ remaining' = [remaining EXCEPT ![t] = @ - Principal(t)]
    /\ participants' = [participants EXCEPT ![t] = @ + Principal(t)]
    /\ active' = [active EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<debt, charged, feesOut>>

EmptySettlement(t) ==
    /\ active[t] /\ Principal(t) = 0
    /\ active' = [active EXCEPT ![t] = FALSE]
    /\ UNCHANGED <<remaining, debt, charged, participants, feesOut>>

RetryFee(t) ==
    /\ debt[t] > 0
    /\ remaining' = [remaining EXCEPT ![t] = @ - debt[t]]
    /\ feesOut' = [feesOut EXCEPT ![t] = @ + debt[t]]
    /\ debt' = [debt EXCEPT ![t] = 0]
    /\ UNCHANGED <<charged, participants, active>>

Next ==
    \/ \E t \in Transactions, a \in 1..Deposit, s \in BOOLEAN: Milestone(t, a, s)
    \/ \E t \in Transactions, s \in BOOLEAN: Settlement(t, s)
    \/ \E t \in Transactions: Refund(t) \/ EmptySettlement(t) \/ RetryFee(t)

FeeDebtProtected ==
    \A t \in Transactions:
        /\ remaining[t] >= debt[t]
        /\ debt[t] >= 0
        /\ participants[t] <= Deposit - charged[t]
        /\ participants[t] >= 0
        /\ Deposit = participants[t] + feesOut[t] + remaining[t]

Spec == Init /\ [][Next]_vars
=============================================================================
