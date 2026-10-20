// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentDefaultRegistry} from "./IAgentDefaultRegistry.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title AgentDefaultRegistry
/// @notice Reference implementation of the Agent Default Registry draft. Anyone may record; a record counts only for a
///         reader that trusts its reporter. Counts are kept per reporter, so a count costs one lookup per trusted
///         reporter however many records others have added.
/// @dev Not audited. A reference for the interface.
contract AgentDefaultRegistry is IAgentDefaultRegistry, IERC165 {
    struct Counts {
        uint128 open;
        uint128 cured;
    }

    address private immutable _identityRegistry;

    DefaultRecord[] private _records; // index 0 is a sentinel, so record ids start at 1
    mapping(address => mapping(bytes32 => uint256)) public recordOf; // reporter => loanRef => record id
    mapping(uint256 => uint256[]) private _byAgent;
    mapping(address => uint256[]) private _byOwner;
    mapping(address => mapping(uint256 => Counts)) private _agentCounts; // reporter => agentId
    mapping(address => mapping(address => Counts)) private _ownerCounts; // reporter => owner

    error ZeroOwner();
    error ZeroPrincipal();
    error ZeroLoanRef();
    error AlreadyRecorded(uint256 recordId);
    error UnknownRecord();
    error NotReporter();
    error AlreadyCured();

    constructor(address identityRegistry_) {
        _identityRegistry = identityRegistry_;
        _records.push(); // sentinel
    }

    function identityRegistry() external view returns (address) {
        return _identityRegistry;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IAgentDefaultRegistry).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function recordDefault(uint256 agentId, address owner, address asset, uint256 principal, bytes32 loanRef)
        external
        returns (uint256 recordId)
    {
        if (owner == address(0)) revert ZeroOwner();
        if (principal == 0) revert ZeroPrincipal();
        if (loanRef == bytes32(0)) revert ZeroLoanRef();
        uint256 existing = recordOf[msg.sender][loanRef];
        if (existing != 0) revert AlreadyRecorded(existing);

        recordId = _records.length;
        _records.push(
            DefaultRecord({
                reporter: msg.sender,
                agentId: agentId,
                owner: owner,
                asset: asset,
                principal: principal,
                loanRef: loanRef,
                defaultedAt: uint64(block.timestamp),
                curedAt: 0,
                recovered: 0
            })
        );
        recordOf[msg.sender][loanRef] = recordId;
        _byAgent[agentId].push(recordId);
        _byOwner[owner].push(recordId);
        _agentCounts[msg.sender][agentId].open += 1;
        _ownerCounts[msg.sender][owner].open += 1;

        emit DefaultRecorded(recordId, msg.sender, agentId, owner, asset, principal, loanRef);
    }

    function recordCure(uint256 recordId, uint256 recovered) external {
        if (recordId == 0 || recordId >= _records.length) revert UnknownRecord();
        DefaultRecord storage r = _records[recordId];
        if (r.reporter != msg.sender) revert NotReporter();
        if (r.curedAt != 0) revert AlreadyCured();

        r.curedAt = uint64(block.timestamp);
        r.recovered = recovered;
        Counts storage a = _agentCounts[msg.sender][r.agentId];
        a.open -= 1;
        a.cured += 1;
        Counts storage o = _ownerCounts[msg.sender][r.owner];
        o.open -= 1;
        o.cured += 1;

        emit DefaultCureRecorded(recordId, msg.sender, recovered);
    }

    function getRecord(uint256 recordId) external view returns (DefaultRecord memory) {
        if (recordId == 0 || recordId >= _records.length) revert UnknownRecord();
        return _records[recordId];
    }

    function agentDefaults(uint256 agentId, address[] calldata trustedReporters)
        external
        view
        returns (uint256 open, uint256 cured)
    {
        for (uint256 i; i < trustedReporters.length; ++i) {
            if (_seenBefore(trustedReporters, i)) continue;
            Counts memory c = _agentCounts[trustedReporters[i]][agentId];
            open += c.open;
            cured += c.cured;
        }
    }

    function ownerDefaults(address owner, address[] calldata trustedReporters)
        external
        view
        returns (uint256 open, uint256 cured)
    {
        for (uint256 i; i < trustedReporters.length; ++i) {
            if (_seenBefore(trustedReporters, i)) continue;
            Counts memory c = _ownerCounts[trustedReporters[i]][owner];
            open += c.open;
            cured += c.cured;
        }
    }

    function recordsOfAgent(uint256 agentId, uint256 start, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byAgent[agentId], start, limit);
    }

    function recordsOfOwner(address owner, uint256 start, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byOwner[owner], start, limit);
    }

    /// @dev A reporter listed twice counts once. Quadratic in the reader's own list, which the reader bounds.
    function _seenBefore(address[] calldata list, uint256 i) private pure returns (bool) {
        for (uint256 j; j < i; ++j) {
            if (list[j] == list[i]) return true;
        }
        return false;
    }

    function _page(uint256[] storage ids, uint256 start, uint256 limit) private view returns (uint256[] memory out) {
        if (start >= ids.length) return new uint256[](0);
        uint256 end = start + limit;
        if (end > ids.length || end < start) end = ids.length;
        out = new uint256[](end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = ids[start + i];
        }
    }
}
