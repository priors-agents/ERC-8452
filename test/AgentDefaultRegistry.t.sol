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
        address owner,
        address asset,
        uint256 principal,
        bytes32 loanRef
    );
    event DefaultCureRecorded(uint256 indexed recordId, address indexed reporter, uint256 recovered);

    uint256 constant AGENT = 6592;
    address constant IDENTITY = address(0x8004);
    address constant USDG = address(0x0d5);

    AgentDefaultRegistry reg;
    address lenderA = makeAddr("lenderA");
    address lenderB = makeAddr("lenderB");
    address griefer = makeAddr("griefer");
    address owner = makeAddr("owner");

    function setUp() public {
        reg = new AgentDefaultRegistry(IDENTITY);
    }

    function _ref(address source, uint256 loanId) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, source, loanId));
    }

    function _record(address reporter, uint256 agentId, address who, uint256 loanId) internal returns (uint256) {
        vm.prank(reporter);
        return reg.recordDefault(agentId, who, USDG, 5e6, _ref(reporter, loanId));
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

    // ------------------------------------------------------------- recording

    function test_recordDefault_storesIndexesAndEmits() public {
        bytes32 ref = _ref(lenderA, 77);
        vm.expectEmit(true, true, true, true);
        emit DefaultRecorded(1, lenderA, AGENT, owner, USDG, 5e6, ref);
        uint256 id = _record(lenderA, AGENT, owner, 77);

        assertEq(id, 1);
        IAgentDefaultRegistry.DefaultRecord memory r = reg.getRecord(id);
        assertEq(r.reporter, lenderA);
        assertEq(r.agentId, AGENT);
        assertEq(r.owner, owner);
        assertEq(r.asset, USDG);
        assertEq(r.principal, 5e6);
        assertEq(r.loanRef, ref);
        assertEq(r.defaultedAt, block.timestamp);
        assertEq(r.curedAt, 0);
        assertEq(reg.recordOf(lenderA, ref), id);
        assertEq(reg.recordsOfAgent(AGENT, 0, 10)[0], id);
        assertEq(reg.recordsOfOwner(owner, 0, 10)[0], id);
        assertEq(reg.identityRegistry(), IDENTITY);
    }

    function test_recordDefault_sameLoanTwiceBySameReporter_reverts() public {
        uint256 id = _record(lenderA, AGENT, owner, 77);
        vm.prank(lenderA);
        vm.expectRevert(abi.encodeWithSelector(AgentDefaultRegistry.AlreadyRecorded.selector, id));
        reg.recordDefault(AGENT, owner, USDG, 5e6, _ref(lenderA, 77));
        // the same reference from another reporter is that reporter's own claim
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

    // ------------------------------------------------------------- cures

    function test_recordCure_onlyTheReporter_once_andCountsMove() public {
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
        (uint256 open, uint256 cured) = reg.agentDefaults(AGENT, _trusted(lenderA));
        assertEq(open, 0);
        assertEq(cured, 1);
        (open, cured) = reg.ownerDefaults(owner, _trusted(lenderA));
        assertEq(open, 0);
        assertEq(cured, 1);

        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.AlreadyCured.selector);
        reg.recordCure(id, 1);
        vm.prank(lenderA);
        vm.expectRevert(AgentDefaultRegistry.UnknownRecord.selector);
        reg.recordCure(99, 1);
    }

    // ------------------------------------------------------------- counting

    function test_counts_onlyTrustedReporters() public {
        _record(lenderA, AGENT, owner, 1);
        _record(lenderB, AGENT, owner, 2);
        _record(griefer, AGENT, owner, 3); // anyone can record; nobody has to read it

        (uint256 open,) = reg.agentDefaults(AGENT, _trusted(lenderA));
        assertEq(open, 1);
        (open,) = reg.agentDefaults(AGENT, _trusted(lenderA, lenderB));
        assertEq(open, 2);
        (open,) = reg.agentDefaults(AGENT, new address[](0));
        assertEq(open, 0);
        (open,) = reg.ownerDefaults(owner, _trusted(lenderB));
        assertEq(open, 1);
    }

    function test_counts_aReporterListedTwiceCountsOnce() public {
        _record(lenderA, AGENT, owner, 1);
        (uint256 open,) = reg.agentDefaults(AGENT, _trusted(lenderA, lenderA));
        assertEq(open, 1);
        (open,) = reg.ownerDefaults(owner, _trusted(lenderA, lenderA));
        assertEq(open, 1);
    }

    function test_counts_agentAndOwnerAreSeparate() public {
        address other = makeAddr("other");
        _record(lenderA, AGENT, owner, 1);
        _record(lenderA, AGENT + 1, owner, 2); // the same owner's second agent
        _record(lenderA, AGENT, other, 3); // the agent under a later owner

        (uint256 open,) = reg.agentDefaults(AGENT, _trusted(lenderA));
        assertEq(open, 2);
        (open,) = reg.ownerDefaults(owner, _trusted(lenderA));
        assertEq(open, 2);
        (open,) = reg.ownerDefaults(other, _trusted(lenderA));
        assertEq(open, 1);
    }

    function test_counts_stayCheapWhateverOthersRecord() public {
        _record(lenderA, AGENT, owner, 1);
        for (uint256 i; i < 200; ++i) {
            _record(griefer, AGENT, owner, 1_000 + i);
        }
        address[] memory trusted = _trusted(lenderA);
        uint256 g = gasleft();
        (uint256 open,) = reg.agentDefaults(AGENT, trusted);
        uint256 used = g - gasleft();
        assertEq(open, 1);
        assertLt(used, 10_000);
    }

    function testFuzz_counts_matchTheRecordsOfTrustedReporters(uint8 byA, uint8 byB, uint8 byGriefer, uint8 cured)
        public
    {
        byA = uint8(bound(byA, 0, 20));
        byB = uint8(bound(byB, 0, 20));
        byGriefer = uint8(bound(byGriefer, 0, 20));
        cured = uint8(bound(cured, 0, byA));
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
        for (uint256 i; i < cured; ++i) {
            vm.prank(lenderA);
            reg.recordCure(idsA[i], 0);
        }
        (uint256 open, uint256 c) = reg.agentDefaults(AGENT, _trusted(lenderA, lenderB));
        assertEq(open, uint256(byA) + byB - cured);
        assertEq(c, cured);
        (open, c) = reg.ownerDefaults(owner, _trusted(lenderA, lenderB));
        assertEq(open, uint256(byA) + byB - cured);
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
