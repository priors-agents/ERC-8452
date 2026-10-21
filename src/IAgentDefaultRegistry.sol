// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Agent Default Registry (draft ERC)
/// @notice One contract where lenders record the defaults of their loans to agent identities, keyed by identity and by
///         the owner address the loan recorded, so that any contract can count them against the lenders it trusts.
/// @dev The ERC-165 identifier is `type(IAgentDefaultRegistry).interfaceId`.
interface IAgentDefaultRegistry {
    struct DefaultRecord {
        address reporter; // who recorded it: the lender, or an address it reports from
        address primary; // the reporter's primary when it was recorded (the reporter itself if it had none)
        uint256 agentId;
        address owner; // the identity's owner recorded by the defaulted loan when it was drawn
        address asset;
        uint256 principal;
        bytes32 loanRef; // the reporter's reference to the loan, unique per primary among records not voided
        uint64 recordedAt; // when it was recorded
        uint64 curedAt; // 0 until a cure is recorded
        uint64 voidedAt; // 0 unless it was voided inside the void window
        uint256 recovered; // recorded with the cure
    }

    event DefaultRecorded(
        uint256 indexed recordId,
        address indexed reporter,
        uint256 indexed agentId,
        address primary,
        address owner,
        address asset,
        uint256 principal,
        bytes32 loanRef
    );
    event DefaultCureRecorded(uint256 indexed recordId, address indexed reporter, uint256 recovered);
    event DefaultVoided(uint256 indexed recordId, address indexed by);
    event PrimaryProposed(address indexed reporter, address indexed primary);
    event PrimarySet(address indexed reporter, address indexed primary);

    /// @notice The ERC-721 identity registry the agent ids refer to.
    function identityRegistry() external view returns (address);

    /// @notice Seconds after recording during which a record can be voided. Fixed.
    function voidWindow() external view returns (uint64);

    /// @notice The primary new records of `reporter` are stored under: its accepted primary, or itself.
    function primaryOf(address reporter) external view returns (address);

    /// @notice Proposes `primary` for the caller's future records (it takes effect when `primary` accepts). The zero
    ///         address, or the caller itself, makes the caller its own primary again at once.
    function setPrimary(address primary) external;

    /// @notice Accepts the caller as `reporter`'s primary, as `reporter` proposed.
    function acceptPrimary(address reporter) external;

    /// @notice Stops storing `reporter`'s future records under the caller, its primary. Records already written stay.
    function dropReporter(address reporter) external;

    /// @notice Records a default reported by `msg.sender`, under its primary. Returns the record's id (never 0).
    function recordDefault(uint256 agentId, address owner, address asset, uint256 principal, bytes32 loanRef)
        external
        returns (uint256 recordId);

    /// @notice Records that the default `recordId` was cured, with the amount recovered. Its reporter or its primary
    ///         only, once.
    function recordCure(uint256 recordId, uint256 recovered) external;

    /// @notice Voids `recordId`, a record made by mistake, inside the void window. Its reporter or its primary only.
    function voidRecord(uint256 recordId) external;

    /// @notice The record `recordId`.
    function getRecord(uint256 recordId) external view returns (DefaultRecord memory);

    /// @notice How many defaults of `agentId` are stored under the given primaries: open, cured, and provisional (still
    ///         inside the void window, not cured). Each listed address counts once.
    function agentDefaults(uint256 agentId, address[] calldata trustedPrimaries)
        external
        view
        returns (uint256 open, uint256 cured, uint256 provisional);

    /// @notice The same, for defaults recorded against `owner`.
    function ownerDefaults(address owner, address[] calldata trustedPrimaries)
        external
        view
        returns (uint256 open, uint256 cured, uint256 provisional);

    /// @notice Record ids of `agentId`, oldest first, from `start`, at most `limit`.
    function recordsOfAgent(uint256 agentId, uint256 start, uint256 limit) external view returns (uint256[] memory);

    /// @notice Record ids recorded against `owner`, oldest first, from `start`, at most `limit`.
    function recordsOfOwner(address owner, uint256 start, uint256 limit) external view returns (uint256[] memory);
}
