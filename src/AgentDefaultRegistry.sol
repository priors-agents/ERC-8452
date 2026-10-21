// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IAgentDefaultRegistry} from "./IAgentDefaultRegistry.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title AgentDefaultRegistry
/// @notice Reference implementation of the Agent Default Registry draft. Anyone may record; a record counts only for a
///         reader that trusts the primary it is stored under. Counts are kept per primary, so a count costs one lookup
///         per trusted primary, plus one per record of that primary still inside its void window, however many records
///         others have added.
/// @dev Not audited. A reference for the interface.
contract AgentDefaultRegistry is IAgentDefaultRegistry, IERC165 {
    struct Counts {
        uint128 open; // not cured and not voided, provisional ones included
        uint128 cured;
    }

    /// @notice Three days: long enough to catch a mistake, too short to be paid later to erase a default.
    uint64 public constant VOID_WINDOW = 3 days;

    address private immutable _identityRegistry;

    DefaultRecord[] private _records; // index 0 is a sentinel, so record ids start at 1
    mapping(address => mapping(bytes32 => uint256)) public recordOf; // primary => loanRef => live record id
    mapping(address => address) private _primary; // reporter => accepted primary (0: itself)
    mapping(address => address) public pendingPrimaryOf; // reporter => proposed primary, until it accepts
    mapping(uint256 => uint256[]) private _byAgent;
    mapping(address => uint256[]) private _byOwner;
    mapping(address => mapping(uint256 => Counts)) private _agentCounts; // primary => agentId
    mapping(address => mapping(address => Counts)) private _ownerCounts; // primary => owner
    mapping(address => mapping(uint256 => uint256[])) private _agentIds; // primary => agentId => record ids
    mapping(address => mapping(address => uint256[])) private _ownerIds; // primary => owner => record ids

    error ZeroOwner();
    error ZeroPrincipal();
    error ZeroLoanRef();
    error AlreadyRecorded(uint256 recordId);
    error UnknownRecord();
    error NotReporter();
    error AlreadyCured();
    error AlreadyVoided();
    error VoidWindowClosed();
    error NotProposed();
    error NotPrimary();

    constructor(address identityRegistry_) {
        _identityRegistry = identityRegistry_;
        _records.push(); // sentinel
    }

    function identityRegistry() external view returns (address) {
        return _identityRegistry;
    }

    function voidWindow() external pure returns (uint64) {
        return VOID_WINDOW;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IAgentDefaultRegistry).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------- primaries

    function primaryOf(address reporter) public view returns (address) {
        address p = _primary[reporter];
        return p == address(0) ? reporter : p;
    }

    function setPrimary(address primary) external {
        if (primary == address(0) || primary == msg.sender) {
            delete _primary[msg.sender];
            delete pendingPrimaryOf[msg.sender];
            emit PrimarySet(msg.sender, msg.sender);
        } else {
            pendingPrimaryOf[msg.sender] = primary;
            emit PrimaryProposed(msg.sender, primary);
        }
    }

    function acceptPrimary(address reporter) external {
        if (pendingPrimaryOf[reporter] != msg.sender) revert NotProposed();
        delete pendingPrimaryOf[reporter];
        _primary[reporter] = msg.sender;
        emit PrimarySet(reporter, msg.sender);
    }

    function dropReporter(address reporter) external {
        if (_primary[reporter] != msg.sender) revert NotPrimary();
        delete _primary[reporter];
        emit PrimarySet(reporter, reporter);
    }

    // ------------------------------------------------------------- records

    function recordDefault(uint256 agentId, address owner, address asset, uint256 principal, bytes32 loanRef)
        external
        returns (uint256 recordId)
    {
        if (owner == address(0)) revert ZeroOwner();
        if (principal == 0) revert ZeroPrincipal();
        if (loanRef == bytes32(0)) revert ZeroLoanRef();
        address primary = primaryOf(msg.sender); // resolved now and stored: later links never move this record
        uint256 existing = recordOf[primary][loanRef];
        if (existing != 0) revert AlreadyRecorded(existing);

        recordId = _records.length;
        _records.push(
            DefaultRecord({
                reporter: msg.sender,
                primary: primary,
                agentId: agentId,
                owner: owner,
                asset: asset,
                principal: principal,
                loanRef: loanRef,
                recordedAt: uint64(block.timestamp),
                curedAt: 0,
                voidedAt: 0,
                recovered: 0
            })
        );
        recordOf[primary][loanRef] = recordId;
        _byAgent[agentId].push(recordId);
        _byOwner[owner].push(recordId);
        _agentIds[primary][agentId].push(recordId);
        _ownerIds[primary][owner].push(recordId);
        _agentCounts[primary][agentId].open += 1;
        _ownerCounts[primary][owner].open += 1;

        emit DefaultRecorded(recordId, msg.sender, agentId, primary, owner, asset, principal, loanRef);
    }

    function recordCure(uint256 recordId, uint256 recovered) external {
        DefaultRecord storage r = _live(recordId);
        r.curedAt = uint64(block.timestamp);
        r.recovered = recovered;
        Counts storage a = _agentCounts[r.primary][r.agentId];
        a.open -= 1;
        a.cured += 1;
        Counts storage o = _ownerCounts[r.primary][r.owner];
        o.open -= 1;
        o.cured += 1;

        emit DefaultCureRecorded(recordId, msg.sender, recovered);
    }

    function voidRecord(uint256 recordId) external {
        DefaultRecord storage r = _live(recordId);
        if (block.timestamp >= uint256(r.recordedAt) + VOID_WINDOW) revert VoidWindowClosed();
        r.voidedAt = uint64(block.timestamp);
        _agentCounts[r.primary][r.agentId].open -= 1;
        _ownerCounts[r.primary][r.owner].open -= 1;
        delete recordOf[r.primary][r.loanRef]; // the loan can be recorded again, correctly

        emit DefaultVoided(recordId, msg.sender);
    }

    function getRecord(uint256 recordId) external view returns (DefaultRecord memory) {
        if (recordId == 0 || recordId >= _records.length) revert UnknownRecord();
        return _records[recordId];
    }

    // ------------------------------------------------------------- counting and listing

    function agentDefaults(uint256 agentId, address[] calldata trustedPrimaries)
        external
        view
        returns (uint256 open, uint256 cured, uint256 provisional)
    {
        for (uint256 i; i < trustedPrimaries.length; ++i) {
            if (_seenBefore(trustedPrimaries, i)) continue;
            Counts memory c = _agentCounts[trustedPrimaries[i]][agentId];
            uint256 p = _provisional(_agentIds[trustedPrimaries[i]][agentId]);
            open += c.open - p;
            cured += c.cured;
            provisional += p;
        }
    }

    function ownerDefaults(address owner, address[] calldata trustedPrimaries)
        external
        view
        returns (uint256 open, uint256 cured, uint256 provisional)
    {
        for (uint256 i; i < trustedPrimaries.length; ++i) {
            if (_seenBefore(trustedPrimaries, i)) continue;
            Counts memory c = _ownerCounts[trustedPrimaries[i]][owner];
            uint256 p = _provisional(_ownerIds[trustedPrimaries[i]][owner]);
            open += c.open - p;
            cured += c.cured;
            provisional += p;
        }
    }

    function recordsOfAgent(uint256 agentId, uint256 start, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byAgent[agentId], start, limit);
    }

    function recordsOfOwner(address owner, uint256 start, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byOwner[owner], start, limit);
    }

    /// @dev A record its reporter, or the primary it is stored under, may act on: it exists, is not voided, not cured.
    function _live(uint256 recordId) private view returns (DefaultRecord storage r) {
        if (recordId == 0 || recordId >= _records.length) revert UnknownRecord();
        r = _records[recordId];
        if (msg.sender != r.reporter && msg.sender != r.primary) revert NotReporter();
        if (r.voidedAt != 0) revert AlreadyVoided();
        if (r.curedAt != 0) revert AlreadyCured();
    }

    /// @dev Records of one primary still inside their void window, neither cured nor voided. Ids are in recording
    ///      order, so the scan stops at the first record past its window: it costs one read per record of the reader's
    ///      own primaries recorded in the last VOID_WINDOW, nothing for anyone else's.
    function _provisional(uint256[] storage ids) private view returns (uint256 n) {
        for (uint256 i = ids.length; i > 0; --i) {
            DefaultRecord storage r = _records[ids[i - 1]];
            if (block.timestamp >= uint256(r.recordedAt) + VOID_WINDOW) break;
            if (r.curedAt == 0 && r.voidedAt == 0) ++n;
        }
    }

    /// @dev An address listed twice counts once. Quadratic in the reader's own list, which the reader bounds.
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
