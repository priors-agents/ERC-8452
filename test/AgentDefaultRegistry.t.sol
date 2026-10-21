// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IAgentDefaultRegistry} from "../src/IAgentDefaultRegistry.sol";
import {AgentDefaultRegistry} from "../src/AgentDefaultRegistry.sol";

contract AgentDefaultRegistryTest is Test {
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

    uint256 constant AGENT = 6592;
    address constant IDENTITY = address(0x8004);
    address constant USDG = address(0x0d5);

    AgentDefaultRegistry reg;
    uint64 window;
    address lenderA = makeAddr("lenderA");
    address lenderB = makeAddr("lenderB");
    address servicer = makeAddr("servicer"); // reports lenderA's loans from its own address
    address griefer = makeAddr("griefer");
    address owner = makeAddr("owner");

    function setUp() public {
        reg = new AgentDefaultRegistry(IDENTITY);
        window = reg.voidWindow();
    }

    function _ref(address source, uint256 loanId) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, source, loanId));
    }

    function _record(address reporter, uint256 agentId, address who, uint256 loanId) internal returns (uint256) {
        vm.prank(reporter);
        return reg.recordDefault(agentId, who, USDG, 5e6, _ref(reporter, loanId));
    }

    function _recordRef(address reporter, bytes32 ref) internal returns (uint256) {
        vm.prank(reporter);
        return reg.recordDefault(AGENT, owner, USDG, 5e6, ref);
    }

    function _trusted(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _trusted(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        l[0] = a;
        l[1] = b;
    }

    function _link(address reporter, address primary) internal {
        vm.prank(reporter);
        reg.setPrimary(primary);
        vm.prank(primary);
        reg.acceptPrimary(reporter);
    }

    function _agent(address[] memory trusted) internal view returns (uint256 open, uint256 cured, uint256 prov) {
        return reg.agentDefaults(AGENT, trusted);
    }

    function _settled() internal {
        vm.warp(block.timestamp + window); // every record so far is past its void window
    }

    // ------------------------------------------------------------- recording

    function test_recordDefault_storesIndexesAndEmits() public {
        bytes32 ref = _ref(lenderA, 77);
        vm.expectEmit(true, true, true, true);
        emit DefaultRecorded(1, lenderA, AGENT, lenderA, owner, USDG, 5e6, ref);
        uint256 id = _record(lenderA, AGENT, owner, 77);

        assertEq(id, 1);
        IAgentDefaultRegistry.DefaultRecord memory r = reg.getRecord(id);
        assertEq(r.reporter, lenderA);
        assertEq(r.primary, lenderA);
        assertEq(r.agentId, AGENT);
        assertEq(r.owner, owner);
        assertEq(r.asset, USDG);
        assertEq(r.principal, 5e6);
        assertEq(r.loanRef, ref);
        assertEq(r.recordedAt, block.timestamp);
        assertEq(r.curedAt, 0);
        assertEq(r.voidedAt, 0);
        assertEq(reg.recordOf(lenderA, ref), id);
        assertEq(reg.recordsOfAgent(AGENT, 0, 10)[0], id);
        assertEq(reg.recordsOfOwner(owner, 0, 10)[0], id);
        assertEq(reg.identityRegistry(), IDENTITY);
    }

    function test_recordDefault_sameLoanTwiceUnderOnePrimary_reverts() public {
        uint256 id = _record(lenderA, AGENT, owner, 77);
        vm.prank(lenderA);
        vm.expectRevert(abi.encodeWithSelector(AgentDefaultRegistry.AlreadyRecorded.selector, id));
        reg.recordDefault(AGENT, owner, USDG, 5e6, _ref(lenderA, 77));
        // the same reference from an unrelated reporter is that reporter's own claim
        vm.prank(lenderB);
        reg.recordDefault(AGENT, owner, USDG, 5e6, _ref(lenderA, 77));
    }

    function test_recordDefault_rejectsEmptyFields() public {
        vm.startPrank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.ZeroOwner.selector);
        reg.recordDefault(AGENT, address(0), USDG, 5e6, bytes32(uint256(1)));
        vm.expectRevert(AgentDefaultRegistry.ZeroPrincipal.selector);
        reg.recordDefault(AGENT, owner, USDG, 0, bytes32(uint256(1)));
        vm.expectRevert(AgentDefaultRegistry.ZeroLoanRef.selector);
        reg.recordDefault(AGENT, owner, USDG, 5e6, bytes32(0));
        vm.stopPrank();
    }

    function test_getRecord_unknown_reverts() public {
        vm.expectRevert(AgentDefaultRegistry.UnknownRecord.selector);
        reg.getRecord(0);
        vm.expectRevert(AgentDefaultRegistry.UnknownRecord.selector);
        reg.getRecord(1);
    }

    // ------------------------------------------------------------- primaries

    function test_primary_takesEffectOnlyWhenAccepted() public {
        vm.expectEmit(true, true, false, false);
        emit PrimaryProposed(servicer, lenderA);
        vm.prank(servicer);
        reg.setPrimary(lenderA);
        assertEq(reg.primaryOf(servicer), servicer); // proposed, not accepted
        assertEq(reg.pendingPrimaryOf(servicer), lenderA);

        // nobody but the proposed primary can accept, so no one can place its records under a lender
        vm.prank(griefer);
        vm.expectRevert(AgentDefaultRegistry.NotProposed.selector);
        reg.acceptPrimary(servicer);
        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.NotProposed.selector);
        reg.acceptPrimary(griefer);

        vm.expectEmit(true, true, false, false);
        emit PrimarySet(servicer, lenderA);
        vm.prank(lenderA);
        reg.acceptPrimary(servicer);
        assertEq(reg.primaryOf(servicer), lenderA);
        assertEq(reg.pendingPrimaryOf(servicer), address(0));
    }

    function test_primary_countsUnderThePrimary_oneRecordPerLoanAcrossItsReporters() public {
        _link(servicer, lenderA);
        bytes32 ref = _ref(address(0xCAFE), 7); // the loan's own reference, the same whoever reports it
        uint256 id = _recordRef(servicer, ref);
        assertEq(reg.getRecord(id).primary, lenderA);
        assertEq(reg.recordOf(lenderA, ref), id);

        // the lender itself cannot record the same loan again under its primary
        vm.prank(lenderA);
        vm.expectRevert(abi.encodeWithSelector(AgentDefaultRegistry.AlreadyRecorded.selector, id));
        reg.recordDefault(AGENT, owner, USDG, 5e6, ref);

        _settled();
        (uint256 open,,) = _agent(_trusted(lenderA));
        assertEq(open, 1);
        (open,,) = _agent(_trusted(servicer)); // the alias holds nothing of its own
        assertEq(open, 0);
    }

    function test_primary_resolvedAtRecordTime_neverShiftsExistingCounts() public {
        bytes32 ref = _ref(address(0xCAFE), 7);
        uint256 before = _recordRef(servicer, ref); // before naming a primary: stays under the servicer
        _link(servicer, lenderA);
        // recording first and linking afterwards does not get around the one-record-per-loan rule under the primary:
        // the earlier record is under the servicer, so the primary can take the loan once
        uint256 again = _recordRef(servicer, ref);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(AgentDefaultRegistry.AlreadyRecorded.selector, again));
        reg.recordDefault(AGENT, owner, USDG, 5e6, ref);

        _link(servicer, lenderB); // moving to another primary
        _settled();
        assertEq(reg.getRecord(before).primary, servicer);
        assertEq(reg.getRecord(again).primary, lenderA);
        (uint256 openA,,) = _agent(_trusted(lenderA));
        (uint256 openB,,) = _agent(_trusted(lenderB));
        (uint256 openS,,) = _agent(_trusted(servicer));
        assertEq(openA, 1);
        assertEq(openB, 0);
        assertEq(openS, 1);
    }

    function test_primary_resetToSelf_andDroppedByThePrimary() public {
        _link(servicer, lenderA);
        vm.expectEmit(true, true, false, false);
        emit PrimarySet(servicer, servicer);
        vm.prank(servicer);
        reg.setPrimary(address(0));
        assertEq(reg.primaryOf(servicer), servicer);

        _link(servicer, lenderA);
        vm.prank(lenderB);
        vm.expectRevert(AgentDefaultRegistry.NotPrimary.selector);
        reg.dropReporter(servicer);
        vm.prank(lenderA);
        reg.dropReporter(servicer);
        assertEq(reg.primaryOf(servicer), servicer);
        uint256 id = _record(servicer, AGENT, owner, 1);
        assertEq(reg.getRecord(id).primary, servicer);
    }

    // ------------------------------------------------------------- cures

    function test_recordCure_byTheReporterOrItsPrimary_once_andCountsMove() public {
        uint256 id = _record(lenderA, AGENT, owner, 77);
        vm.prank(griefer);
        vm.expectRevert(AgentDefaultRegistry.NotReporter.selector);
        reg.recordCure(id, 5e6);

        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, true, false, true);
        emit DefaultCureRecorded(id, lenderA, 6e6);
        vm.prank(lenderA);
        reg.recordCure(id, 6e6);

        IAgentDefaultRegistry.DefaultRecord memory r = reg.getRecord(id);
        assertEq(r.curedAt, block.timestamp);
        assertEq(r.recovered, 6e6);
        (uint256 open, uint256 cured, uint256 prov) = _agent(_trusted(lenderA));
        assertEq(open, 0);
        assertEq(cured, 1);
        assertEq(prov, 0); // a cured record is final, inside the window or not
        (open, cured,) = reg.ownerDefaults(owner, _trusted(lenderA));
        assertEq(open, 0);
        assertEq(cured, 1);

        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.AlreadyCured.selector);
        reg.recordCure(id, 1);
        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.UnknownRecord.selector);
        reg.recordCure(99, 1);

        // the primary cures a record its servicer wrote
        _link(servicer, lenderB);
        uint256 s = _record(servicer, AGENT, owner, 5);
        vm.prank(lenderB);
        reg.recordCure(s, 0);
        assertGt(reg.getRecord(s).curedAt, 0);
    }

    // ------------------------------------------------------------- voids and provisional records

    function test_void_insideTheWindow_countsNothing_andFreesTheLoanRef() public {
        uint256 id = _record(lenderA, AGENT, owner, 77);
        (uint256 open,, uint256 prov) = _agent(_trusted(lenderA));
        assertEq(open, 0);
        assertEq(prov, 1); // inside the window it is reported apart

        vm.prank(griefer);
        vm.expectRevert(AgentDefaultRegistry.NotReporter.selector);
        reg.voidRecord(id);

        vm.warp(block.timestamp + window - 1);
        vm.expectEmit(true, true, false, false);
        emit DefaultVoided(id, lenderA);
        vm.prank(lenderA);
        reg.voidRecord(id);

        assertEq(reg.getRecord(id).voidedAt, block.timestamp);
        _settled();
        (uint256 o, uint256 c, uint256 p) = _agent(_trusted(lenderA));
        assertEq(o + c + p, 0); // neither open nor cured
        (o, c, p) = reg.ownerDefaults(owner, _trusted(lenderA));
        assertEq(o + c + p, 0);
        assertEq(reg.recordsOfAgent(AGENT, 0, 10).length, 1); // never deleted

        // the reference is free again, so the correct record can be written
        uint256 fixedId = _record(lenderA, AGENT, owner, 77);
        assertEq(reg.recordOf(lenderA, _ref(lenderA, 77)), fixedId);

        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.AlreadyVoided.selector);
        reg.voidRecord(id);
        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.AlreadyVoided.selector);
        reg.recordCure(id, 1);
    }

    function test_void_afterTheWindow_orOnACure_reverts() public {
        uint256 id = _record(lenderA, AGENT, owner, 1);
        vm.warp(block.timestamp + window);
        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.VoidWindowClosed.selector);
        reg.voidRecord(id);

        uint256 cured = _record(lenderA, AGENT, owner, 2);
        vm.prank(lenderA);
        reg.recordCure(cured, 0);
        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.AlreadyCured.selector);
        reg.voidRecord(cured);
    }

    function test_void_byThePrimary_ofARecordItsReporterWrote() public {
        _link(servicer, lenderA);
        uint256 id = _record(servicer, AGENT, owner, 1);
        vm.prank(lenderA);
        reg.voidRecord(id);
        assertGt(reg.getRecord(id).voidedAt, 0);
    }

    function test_provisional_becomesOpenWhenTheWindowCloses() public {
        _record(lenderA, AGENT, owner, 1);
        vm.warp(block.timestamp + 1 days);
        _record(lenderA, AGENT, owner, 2);
        (uint256 open,, uint256 prov) = _agent(_trusted(lenderA));
        assertEq(open, 0);
        assertEq(prov, 2);
        vm.warp(block.timestamp + window - 1 days); // the first is past its window, the second is not
        (open,, prov) = _agent(_trusted(lenderA));
        assertEq(open, 1);
        assertEq(prov, 1);
        _settled();
        (open,, prov) = reg.ownerDefaults(owner, _trusted(lenderA));
        assertEq(open, 2);
        assertEq(prov, 0);
    }

    function test_voidWindow_isDays() public view {
        assertGe(window, 1 days);
        assertLe(window, 7 days);
    }

    // ------------------------------------------------------------- counting

    function test_counts_onlyTrustedPrimaries() public {
        _record(lenderA, AGENT, owner, 1);
        _record(lenderB, AGENT, owner, 2);
        _record(griefer, AGENT, owner, 3); // anyone can record; nobody has to read it
        _settled();

        (uint256 open,,) = _agent(_trusted(lenderA));
        assertEq(open, 1);
        (open,,) = _agent(_trusted(lenderA, lenderB));
        assertEq(open, 2);
        (open,,) = _agent(new address[](0));
        assertEq(open, 0);
        (open,,) = reg.ownerDefaults(owner, _trusted(lenderB));
        assertEq(open, 1);
    }

    function test_counts_anAddressListedTwiceCountsOnce() public {
        _record(lenderA, AGENT, owner, 1);
        (uint256 open,, uint256 prov) = _agent(_trusted(lenderA, lenderA));
        assertEq(open + prov, 1);
        _settled();
        (open,,) = reg.ownerDefaults(owner, _trusted(lenderA, lenderA));
        assertEq(open, 1);
    }

    function test_counts_agentAndOwnerAreSeparate() public {
        address other = makeAddr("other");
        _record(lenderA, AGENT, owner, 1);
        _record(lenderA, AGENT + 1, owner, 2); // the same owner's second agent
        _record(lenderA, AGENT, other, 3); // the agent under a later owner
        _settled();

        (uint256 open,,) = _agent(_trusted(lenderA));
        assertEq(open, 2);
        (open,,) = reg.ownerDefaults(owner, _trusted(lenderA));
        assertEq(open, 2);
        (open,,) = reg.ownerDefaults(other, _trusted(lenderA));
        assertEq(open, 1);
    }

    function test_counts_stayCheapWhateverOthersRecord() public {
        _record(lenderA, AGENT, owner, 1);
        _settled();
        for (uint256 i; i < 200; ++i) {
            _record(griefer, AGENT, owner, 1_000 + i); // all inside their window: the most a scan could cost
        }
        address[] memory trusted = _trusted(lenderA);
        uint256 g = gasleft();
        (uint256 open,,) = reg.agentDefaults(AGENT, trusted);
        uint256 used = g - gasleft();
        assertEq(open, 1);
        assertLt(used, 15_000);
    }

    function testFuzz_counts_matchTheRecordsOfTrustedPrimaries(
        uint8 byA,
        uint8 byB,
        uint8 byGriefer,
        uint8 cured,
        uint8 voided
    ) public {
        byA = uint8(bound(byA, 0, 20));
        byB = uint8(bound(byB, 0, 20));
        byGriefer = uint8(bound(byGriefer, 0, 20));
        cured = uint8(bound(cured, 0, byA));
        voided = uint8(bound(voided, 0, byA - cured));
        uint256[] memory idsA = new uint256[](byA);
        for (uint256 i; i < byA; ++i) {
            idsA[i] = _record(lenderA, AGENT, owner, i + 1);
        }
        for (uint256 i; i < byB; ++i) {
            _record(lenderB, AGENT, owner, i + 1);
        }
        for (uint256 i; i < byGriefer; ++i) {
            _record(griefer, AGENT, owner, i + 1);
        }
        vm.startPrank(lenderA);
        for (uint256 i; i < cured; ++i) {
            reg.recordCure(idsA[i], 0);
        }
        for (uint256 i; i < voided; ++i) {
            reg.voidRecord(idsA[cured + i]);
        }
        vm.stopPrank();

        uint256 live = uint256(byA) + byB - cured - voided;
        (uint256 open, uint256 c, uint256 prov) = _agent(_trusted(lenderA, lenderB));
        assertEq(open, 0);
        assertEq(prov, live);
        assertEq(c, cured);
        _settled();
        (open, c, prov) = reg.ownerDefaults(owner, _trusted(lenderA, lenderB));
        assertEq(open, live);
        assertEq(prov, 0);
        assertEq(c, cured);
        assertEq(reg.recordsOfAgent(AGENT, 0, type(uint256).max).length, uint256(byA) + byB + byGriefer);
    }

    // ------------------------------------------------------------- pages and interface

    function test_pages() public {
        for (uint256 i; i < 5; ++i) {
            _record(lenderA, AGENT, owner, i + 1);
        }
        uint256[] memory p = reg.recordsOfAgent(AGENT, 1, 2);
        assertEq(p.length, 2);
        assertEq(p[0], 2);
        assertEq(p[1], 3);
        assertEq(reg.recordsOfAgent(AGENT, 4, 10).length, 1);
        assertEq(reg.recordsOfAgent(AGENT, 5, 10).length, 0);
        assertEq(reg.recordsOfOwner(owner, 0, type(uint256).max).length, 5);
    }

    function test_supportsInterface() public view {
        assertTrue(reg.supportsInterface(type(IAgentDefaultRegistry).interfaceId));
        assertTrue(reg.supportsInterface(0x01ffc9a7));
        assertFalse(reg.supportsInterface(0xffffffff));
    }
}
