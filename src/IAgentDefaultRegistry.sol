// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Agent Default Registry (draft ERC)
/// @notice One contract where lenders record the defaults of their loans to agent identities, keyed by identity and by
///         the owner address the loan recorded, so that any contract can count them against the reporters it trusts.
/// @dev The ERC-165 identifier is `type(IAgentDefaultRegistry).interfaceId`.
interface IAgentDefaultRegistry {
    struct DefaultRecord {
        address reporter; // who recorded it: the lender, or the address it reports from
        uint256 agentId;
        address owner; // the identity's owner recorded by the defaulted loan
        address asset;
        uint256 principal;
        bytes32 loanRef; // the reporter's reference to the loan, unique per reporter
        uint64 defaultedAt; // when it was recorded
        uint64 curedAt; // 0 until the reporter records a cure
        uint256 recovered; // recorded with the cure
    }

    event DefaultRecorded(
        uint256 indexed recordId,
        address indexed reporter,
        uint256 indexed agentId,
        address owner,
        address asset,
        uint256 principal,
        bytes32 loanRef
    );
    event DefaultCureRecorded(uint256 indexed recordId, address indexed reporter, uint256 recovered);

    /// @notice The ERC-721 identity registry the agent ids refer to.
    function identityRegistry() external view returns (address);

    /// @notice Records a default reported by `msg.sender`. Returns the record's id (never 0).
    function recordDefault(uint256 agentId, address owner, address asset, uint256 principal, bytes32 loanRef)
        external
        returns (uint256 recordId);

    /// @notice Records that the default `recordId` was cured, with the amount recovered. Its reporter only, once.
    function recordCure(uint256 recordId, uint256 recovered) external;

    /// @notice The record `recordId`.
    function getRecord(uint256 recordId) external view returns (DefaultRecord memory);

    /// @notice How many defaults of `agentId` the given reporters recorded, open and cured. Each reporter counts once.
    function agentDefaults(uint256 agentId, address[] calldata trustedReporters)
        external
        view
        returns (uint256 open, uint256 cured);

    /// @notice How many defaults recorded against `owner` the given reporters recorded, open and cured.
    function ownerDefaults(address owner, address[] calldata trustedReporters)
        external
        view
        returns (uint256 open, uint256 cured);

    /// @notice Record ids of `agentId`, oldest first, from `start`, at most `limit`.
    function recordsOfAgent(uint256 agentId, uint256 start, uint256 limit) external view returns (uint256[] memory);

    /// @notice Record ids recorded against `owner`, oldest first, from `start`, at most `limit`.
    function recordsOfOwner(address owner, uint256 start, uint256 limit) external view returns (uint256[] memory);
}
