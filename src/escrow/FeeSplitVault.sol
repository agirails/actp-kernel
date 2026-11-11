// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * AGIRAILS — Agent Commerce Transaction Protocol (ACTP)
 * https://agirails.io
 */

import {IFeeSplitVault} from "../interfaces/IFeeSplitVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FeeSplitVault - ACTP escrow vault with an integrator fee
 * @notice EscrowVault semantics plus an integrator share taken from what the kernel pays the provider
 *         and, in profile BOTH_AFTER_DISPUTE, a protocol fee and an integrator fee on refunds that
 *         follow a dispute. Fee rules are stated in IFeeSplitVault. No owner, admin, pause or upgrade.
 * @dev An escrow without terms, or whose terms were voided, behaves exactly like EscrowVault.
 */
contract FeeSplitVault is IFeeSplitVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct EscrowData {
        address requester;
        address provider;
        uint256 amount;
        uint256 releasedAmount;
        bool active;
    }

    struct Terms {
        address integrator;
        uint16 bps;
        FeeProfile profile;
    }

    // One slot. Permanent: kept after the escrow record is deleted.
    struct Locked {
        address integrator;
        uint16 bps;
        FeeProfile profile;
        TermsState state;
        uint16 protocolBps;
        bool disputed;
        bool used;
    }

    // Cumulative counters of a live escrow.
    struct Split {
        uint256 providerSide;
        uint256 integratorProviderSide;
        uint256 refundSide;
        uint256 protocolRefundFee;
        uint256 integratorRefundFee;
    }

    // Fields of the kernel's TransactionView that the vault reads.
    struct KernelTx {
        address requester;
        address provider;
        uint256 amount;
        address escrowContract;
        bytes32 escrowId;
        uint16 protocolBps;
    }

    IERC20 public immutable token;
    address public immutable kernel;

    uint16 public constant MAX_INTEGRATOR_BPS = 1000;
    uint256 internal constant MAX_BPS = 10_000;
    // Mirrors ACTPKernel.MAX_PLATFORM_FEE_CAP; a locked rate outside (0, 500] is not a kernel rate.
    uint256 internal constant MAX_PROTOCOL_BPS = 500;
    // Static prefix of IACTPKernel.TransactionView, in words.
    uint256 internal constant TX_VIEW_WORDS = 21;

    mapping(bytes32 => EscrowData) public escrows;
    mapping(bytes32 => uint256) public bondBalances;
    mapping(address => mapping(address => uint16)) public integratorMaxBps; // provider => integrator => max bps
    mapping(address => mapping(bytes32 => Terms)) internal _pending; // requester => escrowId => terms
    mapping(bytes32 => Locked) internal _locked;
    mapping(bytes32 => Split) internal _split;
    mapping(address => uint256) public integratorCredit;
    uint256 public protocolCredit;
    uint256 public totalLocked;
    uint256 public totalBonds;
    uint256 public totalIntegratorCredit;

    event EscrowCreated(bytes32 indexed escrowId, address indexed requester, address indexed provider, uint256 amount);
    event EscrowPayout(bytes32 indexed escrowId, address indexed recipient, uint256 amount);
    event EscrowCompleted(bytes32 indexed escrowId, uint256 totalReleased);

    constructor(address _token, address _kernel) {
        require(_token != address(0) && _kernel != address(0), "Zero address");
        require(_token != _kernel, "Token and kernel must differ");
        token = IERC20(_token);
        kernel = _kernel;
    }

    modifier onlyKernel() {
        // Authorization: only kernel coordinator
        require(msg.sender == kernel, "Only kernel");
        _;
    }

    // ---------------------------------------------------------------------
    // Consent and registration
    // ---------------------------------------------------------------------

    /// @notice Provider consent: `integrator` may take up to `maxBps` of this provider's payouts.
    /// @dev Checked when an escrow is created; terms already locked are not affected by a later change.
    function setIntegratorApproval(address integrator, uint16 maxBps) external override {
        require(_validIntegrator(integrator), "Invalid integrator");
        require(maxBps <= MAX_INTEGRATOR_BPS, "Bps above cap");
        integratorMaxBps[msg.sender][integrator] = maxBps;
        emit IntegratorApprovalSet(msg.sender, integrator, maxBps);
    }

    /// @notice Requester registers the terms the next `createEscrow(escrowId)` from this requester locks.
    /// @dev Keyed by msg.sender, so nobody can register terms for another requester's escrow.
    function setEscrowTerms(bytes32 escrowId, address integrator, uint16 bps, FeeProfile profile) external override {
        require(escrowId != bytes32(0), "Invalid escrow ID");
        require(_validIntegrator(integrator), "Invalid integrator");
        require(bps > 0, "Bps zero");
        require(bps <= MAX_INTEGRATOR_BPS, "Bps above cap");
        require(!_locked[escrowId].used, "Escrow ID used");
        _pending[msg.sender][escrowId] = Terms({integrator: integrator, bps: bps, profile: profile});
        emit EscrowTermsRegistered(msg.sender, escrowId, integrator, bps, profile);
    }

    function clearEscrowTerms(bytes32 escrowId) external override {
        require(_pending[msg.sender][escrowId].integrator != address(0), "No terms");
        delete _pending[msg.sender][escrowId];
        emit EscrowTermsCleared(msg.sender, escrowId);
    }

    function pendingTerms(address requester, bytes32 escrowId)
        external
        view
        override
        returns (address integrator, uint16 bps, FeeProfile profile)
    {
        Terms memory t = _pending[requester][escrowId];
        return (t.integrator, t.bps, t.profile);
    }

    // ---------------------------------------------------------------------
    // Kernel-only escrow lifecycle
    // ---------------------------------------------------------------------

    function createEscrow(bytes32 escrowId, address requester, address provider, uint256 amount) external override onlyKernel nonReentrant {
        require(escrows[escrowId].amount == 0, "Escrow exists");
        require(requester != address(0) && provider != address(0), "Zero address");
        require(amount > 0, "Amount zero");
        // The escrow record is deleted on completion; this flag is not, so an id is used once.
        require(!_locked[escrowId].used, "Escrow ID used");

        Terms memory t = _pending[requester][escrowId];
        TermsState state = TermsState.NONE;
        if (t.integrator != address(0)) {
            require(t.integrator != provider, "Invalid integrator");
            require(t.bps <= integratorMaxBps[provider][t.integrator], "Integrator not approved");
            // Early check: terms are only meaningful when escrowId is the id of the transaction being
            // linked. The kernel writes escrowContract after this call, so it must still be zero.
            (bool ok, KernelTx memory k) = _readTx(escrowId);
            require(
                ok && k.requester == requester && k.provider == provider && k.amount == amount
                    && k.escrowContract == address(0),
                "Terms need txId escrowId"
            );
            delete _pending[requester][escrowId];
            state = TermsState.PENDING_CONFIRM;
        }
        _locked[escrowId] = Locked({
            integrator: t.integrator,
            bps: t.bps,
            profile: t.profile,
            state: state,
            protocolBps: 0,
            disputed: false,
            used: true
        });

        escrows[escrowId] = EscrowData({
            requester: requester,
            provider: provider,
            amount: amount,
            releasedAmount: 0,
            active: true
        });
        totalLocked += amount;

        token.safeTransferFrom(requester, address(this), amount);

        // State changes must be observable
        emit EscrowCreated(escrowId, requester, provider, amount);
        if (state == TermsState.PENDING_CONFIRM) {
            emit IntegratorTermsLocked(escrowId, provider, t.integrator, t.bps, t.profile);
        }
    }

    function verifyEscrow(
        bytes32 escrowId,
        address requester,
        address provider,
        uint256 amount
    ) external view override returns (bool isActive, uint256 escrowAmount) {
        EscrowData memory e = escrows[escrowId];
        bool matches = e.active && e.requester == requester && e.provider == provider && e.amount >= amount;
        return (matches, e.amount);
    }

    /// @dev `amount` is what the kernel pays the provider side, protocol fee already removed. The
    ///      integrator share comes out of it; the full `amount` is debited and returned.
    function payoutToProvider(bytes32 escrowId, uint256 amount) external override onlyKernel nonReentrant returns (uint256) {
        EscrowData storage e = escrows[escrowId];
        address provider = e.provider;
        require(provider != address(0), "Escrow missing");
        bool complete = _debit(e, amount);

        Locked storage l = _locked[escrowId];
        address integrator = l.integrator;
        bool split = l.bps > 0 && _confirmed(escrowId, l, e);
        uint256 cut;
        if (split) {
            Split storage s = _split[escrowId];
            uint256 providerSide = s.providerSide + amount;
            uint256 target = _integratorProviderTarget(providerSide, e.amount, l.bps, l.protocolBps);
            // target is non-decreasing and rises by at most ceil(amount * b / (10000 - p)) <= amount,
            // because b <= 1000 and p <= 500.
            cut = target - s.integratorProviderSide;
            s.providerSide = providerSide;
            s.integratorProviderSide = target;
        }

        uint256 providerAmount = amount - cut;
        if (providerAmount > 0) {
            token.safeTransfer(provider, providerAmount);
            emit EscrowPayout(escrowId, provider, providerAmount);
        }
        bool credited;
        if (cut > 0) credited = _pushOrCreditIntegrator(escrowId, integrator, cut);
        if (split) {
            emit IntegratorFeeSplit(escrowId, provider, integrator, amount, providerAmount, cut, credited);
        }

        _finish(escrowId, e, complete);
        return amount;
    }

    /// @dev Fees apply only in profile BOTH_AFTER_DISPUTE on an escrow that was disputed. The full
    ///      `amount` is debited and returned in every case.
    function refundToRequester(bytes32 escrowId, uint256 amount) external override onlyKernel nonReentrant returns (uint256) {
        EscrowData storage e = escrows[escrowId];
        address requester = e.requester;
        require(requester != address(0), "Escrow missing");
        bool complete = _debit(e, amount);

        Locked storage l = _locked[escrowId];
        address integrator = l.integrator;
        bool split = l.profile == FeeProfile.BOTH_AFTER_DISPUTE && l.disputed && l.bps > 0
            && _confirmed(escrowId, l, e);
        uint256 protocolFee;
        uint256 integratorFee;
        if (split) {
            Split storage s = _split[escrowId];
            (protocolFee, integratorFee) =
                _refundFees(s.refundSide, s.protocolRefundFee, s.integratorRefundFee, amount, l.protocolBps, l.bps);
            // Store what was actually taken, so a later refund catches up to the cumulative targets.
            s.refundSide += amount;
            s.protocolRefundFee += protocolFee;
            s.integratorRefundFee += integratorFee;
        }

        uint256 requesterAmount = amount - protocolFee - integratorFee;
        if (requesterAmount > 0) {
            token.safeTransfer(requester, requesterAmount);
            emit EscrowPayout(escrowId, requester, requesterAmount);
        }
        bool protocolCredited;
        if (protocolFee > 0) protocolCredited = _pushOrCreditProtocol(escrowId, protocolFee);
        bool integratorCredited;
        if (integratorFee > 0) integratorCredited = _pushOrCreditIntegrator(escrowId, integrator, integratorFee);
        if (split) {
            emit RefundFeeSplit(
                escrowId, requester, integrator, amount, requesterAmount, protocolFee, integratorFee,
                protocolCredited, integratorCredited
            );
        }

        _finish(escrowId, e, complete);
        return amount;
    }

    /// @dev Protocol fee, archive share and mediator payouts. No fee logic.
    function payout(bytes32 escrowId, address recipient, uint256 amount) external override onlyKernel nonReentrant returns (uint256) {
        EscrowData storage e = escrows[escrowId];
        require(recipient != address(0), "Zero recipient");
        bool complete = _debit(e, amount);
        token.safeTransfer(recipient, amount);
        emit EscrowPayout(escrowId, recipient, amount);
        _finish(escrowId, e, complete);
        return amount;
    }

    // AIP-14: Dispute bond methods

    /// @notice Deposit a dispute bond for an escrow. Called by ACTPKernel during dispute opening.
    /// @dev The kernel calls this only on the DELIVERED to DISPUTED transition, so the first bond is
    ///      the complete "this escrow was disputed" signal; no kernel read is needed.
    function depositBond(bytes32 escrowId, address from, uint256 amount) external override onlyKernel nonReentrant {
        require(amount > 0, "Amount zero");
        require(from != address(0), "Zero address");
        token.safeTransferFrom(from, address(this), amount);
        bondBalances[escrowId] += amount;
        totalBonds += amount;
        Locked storage l = _locked[escrowId];
        if (!l.disputed) {
            l.disputed = true;
            emit EscrowDisputed(escrowId);
        }
    }

    /// @notice Release a dispute bond to the designated recipient. Called by ACTPKernel during resolution.
    function releaseBond(bytes32 escrowId, address recipient, uint256 amount) external override onlyKernel nonReentrant {
        require(recipient != address(0), "Zero recipient");
        require(amount > 0, "Amount zero");
        require(bondBalances[escrowId] >= amount, "Insufficient bond");
        bondBalances[escrowId] -= amount;
        totalBonds -= amount;
        token.safeTransfer(recipient, amount);
    }

    /// @notice View the bond balance for an escrow
    function bondBalance(bytes32 escrowId) external view override returns (uint256) {
        return bondBalances[escrowId];
    }

    function remaining(bytes32 escrowId) external view override returns (uint256) {
        EscrowData memory e = escrows[escrowId];
        if (e.amount == 0) return 0;
        return e.amount - e.releasedAmount;
    }

    // ---------------------------------------------------------------------
    // Credits (only used when a fee push fails)
    // ---------------------------------------------------------------------

    /// @notice Permissionless. Pays the whole credit to `integrator` and to nobody else.
    function withdrawIntegratorCredit(address integrator) external override nonReentrant returns (uint256 amount) {
        amount = integratorCredit[integrator];
        require(amount > 0, "No credit");
        integratorCredit[integrator] = 0;
        totalIntegratorCredit -= amount;
        token.safeTransfer(integrator, amount);
        emit IntegratorCreditWithdrawn(integrator, amount);
    }

    /// @notice Permissionless. Pays the whole credit to the kernel's current fee recipient.
    function withdrawProtocolCredit() external override nonReentrant returns (uint256 amount) {
        amount = protocolCredit;
        require(amount > 0, "No credit");
        protocolCredit = 0;
        (bool ok, address recipient) = _feeRecipient();
        require(ok, "Fee recipient unavailable");
        token.safeTransfer(recipient, amount);
        emit ProtocolCreditWithdrawn(recipient, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function lockedTerms(bytes32 escrowId)
        external
        view
        override
        returns (
            address integrator,
            uint16 bps,
            FeeProfile profile,
            TermsState state,
            uint16 protocolBps,
            bool disputed,
            bool used
        )
    {
        Locked memory l = _locked[escrowId];
        return (l.integrator, l.bps, l.profile, l.state, l.protocolBps, l.disputed, l.used);
    }

    function splitState(bytes32 escrowId)
        external
        view
        override
        returns (
            uint256 providerSide,
            uint256 integratorProviderSide,
            uint256 refundSide,
            uint256 protocolRefundFee,
            uint256 integratorRefundFee
        )
    {
        Split memory s = _split[escrowId];
        return (s.providerSide, s.integratorProviderSide, s.refundSide, s.protocolRefundFee, s.integratorRefundFee);
    }

    /// @notice What `payoutToProvider(escrowId, amount)` would pay now.
    function quotePayout(bytes32 escrowId, uint256 amount)
        external
        view
        override
        returns (uint256 providerAmount, uint256 integratorAmount)
    {
        Locked memory l = _locked[escrowId];
        (bool applies, uint16 protocolBps,) = _rate(escrowId, l);
        if (l.bps > 0 && applies) {
            Split memory s = _split[escrowId];
            integratorAmount =
                _integratorProviderTarget(s.providerSide + amount, escrows[escrowId].amount, l.bps, protocolBps)
                    - s.integratorProviderSide;
        }
        providerAmount = amount - integratorAmount;
    }

    /// @notice What `refundToRequester(escrowId, amount)` would pay now. Fee-free while undisputed.
    function quoteRefund(bytes32 escrowId, uint256 amount)
        external
        view
        override
        returns (uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee)
    {
        Locked memory l = _locked[escrowId];
        if (l.disputed) (requesterAmount, protocolFee, integratorFee,) = _quoteDisputedRefund(escrowId, l, amount);
        else requesterAmount = amount;
    }

    /// @notice Hypothetical: the refund split for proposed terms, before any escrow exists.
    function previewDisputeRefund(uint256 refundAmount, uint16 protocolBps, uint16 integratorBps)
        external
        pure
        override
        returns (uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee)
    {
        require(protocolBps > 0 && protocolBps <= MAX_PROTOCOL_BPS, "Bad protocol bps");
        require(integratorBps <= MAX_INTEGRATOR_BPS, "Bps above cap");
        (protocolFee, integratorFee) = _refundFees(0, 0, 0, refundAmount, protocolBps, integratorBps);
        requesterAmount = refundAmount - protocolFee - integratorFee;
    }

    /// @notice Hypothetical: what `refundToRequester(escrowId, amount)` would pay if the escrow were
    ///         disputed now.
    function quoteRefundIfDisputed(bytes32 escrowId, uint256 amount)
        external
        view
        override
        returns (uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee, bool rateConfirmed)
    {
        return _quoteDisputedRefund(escrowId, _locked[escrowId], amount);
    }

    /// @notice The vault's own decoding of `kernel.getTransaction(txId)`, for the deploy gate.
    function kernelViewProbe(bytes32 txId)
        external
        view
        override
        returns (
            bool ok,
            address requester,
            address provider,
            uint256 amount,
            address escrowContract,
            bytes32 escrowId,
            uint16 protocolBps
        )
    {
        KernelTx memory k;
        (ok, k) = _readTx(txId);
        return (ok, k.requester, k.provider, k.amount, k.escrowContract, k.escrowId, k.protocolBps);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _validIntegrator(address integrator) internal view returns (bool) {
        return integrator != address(0) && integrator != msg.sender && integrator != address(this)
            && integrator != kernel && integrator != address(token);
    }

    /// @dev Effects of a disbursement of `amount` from the escrow, before any transfer.
    function _debit(EscrowData storage e, uint256 amount) internal returns (bool complete) {
        require(e.active, "Escrow inactive");
        require(amount > 0, "Amount zero");
        // Fund conservation: disbursement cannot exceed locked amount
        require(amount <= e.amount - e.releasedAmount, "Insufficient escrow");
        e.releasedAmount += amount;
        totalLocked -= amount;
        complete = e.releasedAmount == e.amount;
        if (complete) e.active = false;
    }

    /// @dev Runs after the transfers. The locked terms stay as the permanent record.
    function _finish(bytes32 escrowId, EscrowData storage e, bool complete) internal {
        if (complete) {
            emit EscrowCompleted(escrowId, e.amount);
            delete escrows[escrowId];
            delete _split[escrowId];
        }
    }

    function _pushOrCreditIntegrator(bytes32 escrowId, address integrator, uint256 amount) internal returns (bool credited) {
        if (token.trySafeTransfer(integrator, amount)) {
            emit EscrowPayout(escrowId, integrator, amount);
            return false;
        }
        integratorCredit[integrator] += amount;
        totalIntegratorCredit += amount;
        return true;
    }

    function _pushOrCreditProtocol(bytes32 escrowId, uint256 amount) internal returns (bool credited) {
        (bool ok, address recipient) = _feeRecipient();
        if (ok && token.trySafeTransfer(recipient, amount)) {
            emit EscrowPayout(escrowId, recipient, amount);
            return false;
        }
        protocolCredit += amount;
        return true;
    }

    /// @dev Live `kernel.feeRecipient()`. `ok` is false for a failed call or a zero or malformed address.
    function _feeRecipient() internal view returns (bool ok, address recipient) {
        (bool success, bytes memory ret) = kernel.staticcall(abi.encodeWithSignature("feeRecipient()"));
        if (!success || ret.length < 32) return (false, address(0));
        uint256 word = abi.decode(ret, (uint256));
        if (word == 0 || word >> 160 != 0) return (false, address(0));
        return (true, address(uint160(word)));
    }

    /// @dev Decodes the static prefix of `kernel.getTransaction(id)`: word 1 requester, 2 provider,
    ///      4 amount, 9 escrowContract, 10 escrowId, 14 platformFeeBpsLocked. Never reverts: a failed,
    ///      short or malformed answer is `ok = false`.
    function _readTx(bytes32 id) internal view returns (bool ok, KernelTx memory k) {
        (bool success, bytes memory ret) = kernel.staticcall(abi.encodeWithSignature("getTransaction(bytes32)", id));
        if (!success || ret.length < TX_VIEW_WORDS * 32) return (false, k);
        uint256[TX_VIEW_WORDS] memory w = abi.decode(ret, (uint256[21]));
        if (w[1] >> 160 != 0 || w[2] >> 160 != 0 || w[9] >> 160 != 0) return (false, k);
        // The kernel never locks a zero rate; the bound also keeps 10000 - p positive.
        if (w[14] == 0 || w[14] > MAX_PROTOCOL_BPS) return (false, k);
        k.requester = address(uint160(w[1]));
        k.provider = address(uint160(w[2]));
        k.amount = w[4];
        k.escrowContract = address(uint160(w[9]));
        k.escrowId = bytes32(w[10]);
        k.protocolBps = uint16(w[14]);
        return (true, k);
    }

    /// @dev True when the kernel transaction whose id is `escrowId` is linked to this vault under
    ///      `escrowId` with the escrow's parties. The kernel links an id to a vault at most once, so
    ///      that transaction is the escrow's own.
    function _bound(bytes32 escrowId, address requester, address provider) internal view returns (bool ok, uint16 protocolBps) {
        KernelTx memory k;
        (ok, k) = _readTx(escrowId);
        ok = ok && k.escrowContract == address(this) && k.escrowId == escrowId && k.requester == requester
            && k.provider == provider;
        protocolBps = k.protocolBps;
    }

    /// @dev At the first money movement that needs the protocol rate: read it from the kernel and
    ///      confirm the terms, or void them. Voided terms never apply again.
    function _confirmed(bytes32 escrowId, Locked storage l, EscrowData storage e) internal returns (bool) {
        TermsState state = l.state;
        if (state == TermsState.CONFIRMED) return true;
        if (state != TermsState.PENDING_CONFIRM) return false;
        (bool ok, uint16 protocolBps) = _bound(escrowId, e.requester, e.provider);
        if (ok) {
            l.protocolBps = protocolBps;
            l.state = TermsState.CONFIRMED;
            emit TermsConfirmed(escrowId, protocolBps);
        } else {
            l.state = TermsState.VOID;
            emit TermsVoided(escrowId);
        }
        return ok;
    }

    /// @dev View counterpart of `_confirmed`: whether fee terms apply, and at which protocol rate.
    function _rate(bytes32 escrowId, Locked memory l) internal view returns (bool applies, uint16 protocolBps, bool confirmed) {
        if (l.state == TermsState.CONFIRMED) return (true, l.protocolBps, true);
        if (l.state != TermsState.PENDING_CONFIRM) return (false, 0, true);
        EscrowData memory e = escrows[escrowId];
        (applies, protocolBps) = _bound(escrowId, e.requester, e.provider);
    }

    function _quoteDisputedRefund(bytes32 escrowId, Locked memory l, uint256 amount)
        internal
        view
        returns (uint256 requesterAmount, uint256 protocolFee, uint256 integratorFee, bool rateConfirmed)
    {
        rateConfirmed = true;
        if (l.profile == FeeProfile.BOTH_AFTER_DISPUTE && l.bps > 0) {
            bool applies;
            uint16 protocolBps;
            (applies, protocolBps, rateConfirmed) = _rate(escrowId, l);
            if (applies) {
                Split memory s = _split[escrowId];
                (protocolFee, integratorFee) =
                    _refundFees(s.refundSide, s.protocolRefundFee, s.integratorRefundFee, amount, protocolBps, l.bps);
            }
        }
        requesterAmount = amount - protocolFee - integratorFee;
    }

    /// @dev min(floor(N * b / (10000 - p)), floor(D * b / 10000)).
    function _integratorProviderTarget(uint256 providerSide, uint256 deposit, uint256 bps, uint256 protocolBps)
        internal
        pure
        returns (uint256 target)
    {
        target = (providerSide * bps) / (MAX_BPS - protocolBps);
        uint256 cap = (deposit * bps) / MAX_BPS;
        if (target > cap) target = cap;
    }

    /// @dev Fees of a refund of `amount` on top of the cumulative `refundSide`: the rise of
    ///      floor(R * p / 10000) and of floor(R * min(b, p) / 10000) over what was already taken.
    ///      If both floors step on a refund too small to carry them, the integrator fee gives way
    ///      first, then the protocol fee.
    function _refundFees(
        uint256 refundSide,
        uint256 protocolTaken,
        uint256 integratorTaken,
        uint256 amount,
        uint256 protocolBps,
        uint256 bps
    ) internal pure returns (uint256 protocolFee, uint256 integratorFee) {
        uint256 total = refundSide + amount;
        uint256 refundBps = bps < protocolBps ? bps : protocolBps;
        protocolFee = (total * protocolBps) / MAX_BPS - protocolTaken;
        integratorFee = (total * refundBps) / MAX_BPS - integratorTaken;
        if (protocolFee + integratorFee > amount) {
            uint256 excess = protocolFee + integratorFee - amount;
            uint256 fromIntegrator = excess < integratorFee ? excess : integratorFee;
            integratorFee -= fromIntegrator;
            protocolFee -= excess - fromIntegrator;
        }
    }
}
