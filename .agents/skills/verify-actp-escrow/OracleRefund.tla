---------------------------- MODULE OracleRefund ----------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Transactions
VARIABLES first, ruling, oracle, pending, paid, award, refundable, claimed, timedOut
vars == <<first, ruling, oracle, pending, paid, award, refundable, claimed, timedOut>>

Init ==
    /\ first = [t \in Transactions |-> "none"]
    /\ ruling = [t \in Transactions |-> 0]
    /\ oracle = [t \in Transactions |-> 0]
    /\ pending = [t \in Transactions |-> FALSE]
    /\ paid = [t \in Transactions |-> 0]
    /\ award = [t \in Transactions |-> 0]
    /\ refundable = [t \in Transactions |-> FALSE]
    /\ claimed = [t \in Transactions |-> FALSE]
    /\ timedOut = [t \in Transactions |-> FALSE]

Callback(t, verdict, winner, succeeds) ==
    /\ first[t] = "none"
    /\ first' = [first EXCEPT ![t] = "oracle"]
    /\ oracle' = [oracle EXCEPT ![t] = verdict]
    /\ ruling' = [ruling EXCEPT ![t] = verdict]
    /\ refundable' = [refundable EXCEPT ![t] = ~winner]
    /\ pending' = [pending EXCEPT ![t] = ~succeeds]
    /\ paid' = [paid EXCEPT ![t] = IF succeeds THEN 1 ELSE 0]
    /\ award' = [award EXCEPT ![t] = IF succeeds THEN verdict ELSE 0]
    /\ UNCHANGED <<claimed, timedOut>>

Retry(t) ==
    /\ first[t] = "oracle" /\ pending[t]
    /\ pending' = [pending EXCEPT ![t] = FALSE]
    /\ paid' = [paid EXCEPT ![t] = paid[t] + 1]
    /\ award' = [award EXCEPT ![t] = ruling[t]]
    /\ UNCHANGED <<first, ruling, oracle, refundable, claimed, timedOut>>

Claim(t) ==
    /\ refundable[t] /\ ~claimed[t]
    /\ claimed' = [claimed EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<first, ruling, oracle, pending, paid, award, refundable, timedOut>>

Timeout(t) ==
    /\ ~timedOut[t]
    /\ timedOut' = [timedOut EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<first, ruling, oracle, pending, paid, award, refundable, claimed>>

Stale(t) ==
    /\ first[t] = "none" /\ timedOut[t]
    /\ first' = [first EXCEPT ![t] = "stale"]
    /\ ruling' = [ruling EXCEPT ![t] = 2]
    /\ paid' = [paid EXCEPT ![t] = 1]
    /\ award' = [award EXCEPT ![t] = 2]
    /\ refundable' = [refundable EXCEPT ![t] = TRUE]
    /\ UNCHANGED <<oracle, pending, claimed, timedOut>>

LateCallback(t) ==
    /\ first[t] # "none"
    /\ UNCHANGED vars

Next ==
    \/ \E t \in Transactions, v \in {0, 1}, w \in BOOLEAN, s \in BOOLEAN:
           Callback(t, v, w, s)
    \/ \E t \in Transactions: Retry(t) \/ Claim(t) \/ Timeout(t) \/ Stale(t) \/ LateCallback(t)

OracleAward ==
    \A t \in Transactions:
        /\ paid[t] <= 1
        /\ (first[t] = "oracle" =>
               ruling[t] = oracle[t] /\ (paid[t] = 1 => award[t] = oracle[t]))
        /\ (first[t] = "stale" => award[t] = 2 /\ ruling[t] = 2)

Spec == Init /\ [][Next]_vars
=============================================================================
