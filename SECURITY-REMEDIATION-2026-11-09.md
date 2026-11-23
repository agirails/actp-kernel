# Reputation recovery and escrow verification follow-up

Base: a6c6f4e63b54a0bbbe4ab4752e1ab57889e94180 (merged original five security remediations). Local candidate only; no deployment or commit implied.

Explicit dispute settlement now persists the validated final provider fault before best-effort registry delivery. Existing releaseEscrow retries read that same outcome. Added permissionless, pause-exempt, non-reentrant retryReputation(bytes32) for settled transactions and stalled cancellations. Neutral disputed and ordinary cancellations remain ineligible. Failed/no-code/unregistered/out-of-gas registry delivery leaves the global success latch unset; successful delivery prevents replay even after registry replacement. The retry does not touch escrow, fees, bonds, transaction state or timestamps.

Deployment preflight and VerifyDeployGate require the new selector in addition to fee-recovery selectors. Existing logical version, tuple layout, signed proofs and event topics stay compatible; deployment must pin the actual candidate codehash. See deployments/AIP14C-ABI-FREEZE.md.

Permanent verification is .agents/skills/verify-actp-escrow, exposed through its relative Claude link. It checks two bounded financial properties with TLA+ safety models, real-contract stateful handlers, deterministic non-vacuity controls, separate model/Solidity negative controls and hash drift detection. Its SKILL.md and WRITERS.md state bounds, trusted override exclusions and maintenance. CI checks presence/drift and runs real tests; hosted TLC is not introduced.

Selective historical reputation recovery remains a protocol limitation: a late-registered provider can request favorable credits. Requesters/permissionless keepers must sweep adverse finalized history for completeness. No epoch or new reputation policy is invented in this patch. Third-party adverse retry is covered. Trusted resolver intervention after a deferred oracle callback can leave mediator retry pending and reverting; this accepted authority boundary is documented and tested, not claimed resolved.

Run the full pinned offline Forge suite, the skill with --negative-controls and a subsequent cold positive run, ABI/size/deploy gates, exact CI coverage recipe and code-check diff before accepting a new snapshot. The external evidence package records measured outcomes; this document is not itself a test attestation. Testnet, SDK integration and production chain behavior remain unrun.
