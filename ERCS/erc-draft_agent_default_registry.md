---
eip: 99903
title: Agent Default Registry
description: Lender-reported loan defaults of agent identities, countable on chain against trusted reporters
author: Priors contributors (@priors-agents)
discussions-to: https://ethereum-magicians.org/t/erc-tba-agent-default-registry/30026
status: Draft
type: Standards Track
category: ERC
created: 2026-10-20
requires: 165, 721
---

## Abstract

This proposal defines one contract where lenders record the defaults of loans they made to identities of an
[ERC-721](./eip-721.md) identity registry, such as the Identity Registry of [ERC-8004](./eip-8004.md). Each record names
the identity, the owner address the loan recorded, the asset, the principal and the lender's reference to the loan, and
can later be marked cured with the amount recovered. Anyone may record, and a record counts only for a reader that trusts
its reporter: a contract asks how many open and cured defaults an identity, or an owner address, has according to the
reporters it names, at a cost that grows with that list alone.

## Motivation

A loan that was not repaid is the strongest signal a lender has about a borrower, and today it stays with the lender
that saw it. An agent that defaults with one lender can borrow from the next, and an owner whose agent defaulted can
borrow through another identity. Reputation systems that average scores, or that keep one latest assertion per issuer,
cannot answer the question a lender asks before it lends: how many loans did this identity, or this owner, fail to
repay, according to lenders I trust.

Lenders also need the answer on chain, inside the transaction that opens a line, so the record has to be a contract read
with a bounded cost, not a file to fetch and parse.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT
RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Interface

A registry MUST implement `IAgentDefaultRegistry` and [ERC-165](./eip-165.md), returning `true` for the interface
identifier of `IAgentDefaultRegistry` and for `0x01ffc9a7`.

```solidity
interface IAgentDefaultRegistry {
    struct DefaultRecord {
        address reporter;
        uint256 agentId;
        address owner;
        address asset;
        uint256 principal;
        bytes32 loanRef;
        uint64 defaultedAt;
        uint64 curedAt;
        uint256 recovered;
    }

    event DefaultRecorded(uint256 indexed recordId, address indexed reporter, uint256 indexed agentId, address owner, address asset, uint256 principal, bytes32 loanRef);
    event DefaultCureRecorded(uint256 indexed recordId, address indexed reporter, uint256 recovered);

    function identityRegistry() external view returns (address);
    function recordDefault(uint256 agentId, address owner, address asset, uint256 principal, bytes32 loanRef) external returns (uint256 recordId);
    function recordCure(uint256 recordId, uint256 recovered) external;
    function getRecord(uint256 recordId) external view returns (DefaultRecord memory);
    function agentDefaults(uint256 agentId, address[] calldata trustedReporters) external view returns (uint256 open, uint256 cured);
    function ownerDefaults(address owner, address[] calldata trustedReporters) external view returns (uint256 open, uint256 cured);
    function recordsOfAgent(uint256 agentId, uint256 start, uint256 limit) external view returns (uint256[] memory);
    function recordsOfOwner(address owner, uint256 start, uint256 limit) external view returns (uint256[] memory);
}
```

### Records

- `identityRegistry()` MUST return the ERC-721 contract the `agentId` values refer to, and MUST NOT change.
- `recordDefault` MUST be callable by any account; the caller is the record's `reporter`. It MUST revert if `owner` is
  the zero address, if `principal` is zero, if `loanRef` is zero, or if the same reporter already recorded the same
  `loanRef`. It MUST store the record with `defaultedAt` set to the block timestamp and `curedAt` and `recovered` set
  to zero, give it a `recordId` that is not zero and is never reused, emit `DefaultRecorded`, and return the id.
- `owner` is the address the defaulted loan recorded as the identity's owner when it was drawn, not the current owner.
- `loanRef` is the reporter's reference to the loan. A reporter SHOULD use
  `keccak256(abi.encode(chainId, lendingContract, loanId))`, so that one loan can never be recorded twice by one
  reporter and readers can find the loan's own logs.
- `asset` is the token lent; `principal` is in its base units.
- `recordCure(recordId, recovered)` MUST revert unless called by the record's reporter, and MUST revert if the record
  does not exist or is already cured. It MUST set `curedAt` to the block timestamp and `recovered` to the amount given,
  and emit `DefaultCureRecorded`. A record MUST NOT change in any other way, and MUST NOT be deleted.
- `getRecord` MUST revert for an id that was never issued.

### Counting

- `agentDefaults(agentId, trustedReporters)` MUST return how many records of `agentId` the listed reporters recorded,
  split into those not cured (`open`) and those cured. `ownerDefaults(owner, trustedReporters)` MUST do the same for
  records whose `owner` is `owner`.
- A reporter listed more than once MUST be counted once. Records by reporters not listed MUST NOT be counted.
- The cost of a count MUST NOT grow with the number of records by reporters that are not listed. Implementations keep
  counts per reporter for this reason.

### Listing

`recordsOfAgent` and `recordsOfOwner` MUST return record ids in the order they were recorded, starting at position
`start` and returning at most `limit` ids, and an empty list when `start` is at or past the end.

## Rationale

- **Anyone records, readers choose.** A registry that vets lenders needs an owner and becomes a gatekeeper. Letting
  anyone record and making every count take the reader's list of reporters puts trust where it already is: each lender
  decides whose defaults it believes, as readers of [ERC-8004](./eip-8004.md) feedback choose their clients.
- **Counts, not scores.** Lenders weigh defaults differently; a count of open and cured defaults per trusted reporter is
  what any score is computed from, and it cannot be argued over.
- **By identity and by owner.** An identity can change hands, and an owner can hold many identities. A default is a fact
  about both: the identity that borrowed and the address that answered for it when it borrowed.
- **Per-reporter counts.** Since anyone can record, anyone can add thousands of records to an identity. A lender's
  check runs inside the transaction that opens a line, so its cost has to depend on the lender's own list, not on what
  others recorded.
- **Cures, never deletions.** A default that was later recovered is still a default; a reader decides how much a cure
  is worth. A reporter cannot erase a record, so a reader can rely on what it saw.
- **One record per loan per reporter.** The loan reference stops a reporter from inflating counts by recording the same
  loan twice. Two reporters can record the same loan; a reader that trusts both decides how to treat it.

## Backwards Compatibility

No backward compatibility issues found. Lenders whose contracts cannot call the registry record from an address they
control and publish that address as their reporter.

## Test Cases

A conforming registry passes these cases:

- A record by reporter A for identity 6592 and owner O gets id 1, emits `DefaultRecorded`, and is returned whole by
  `getRecord(1)` and listed by `recordsOfAgent(6592, 0, 10)` and `recordsOfOwner(O, 0, 10)`.
- A recording reverts for a zero owner, a zero principal or a zero loan reference, and for a loan reference reporter A
  already used; reporter B may record the same loan reference.
- With records by A, B and a third reporter for one identity, `agentDefaults` with `[A]` returns one open default, with
  `[A, B]` two, with `[A, A]` one, and with an empty list none.
- A cure by anyone but the reporter reverts; the reporter's cure moves one count from open to cured in both
  `agentDefaults` and `ownerDefaults`; a second cure reverts.
- After 200 records by an untrusted reporter, `agentDefaults` with one trusted reporter costs the same as before them.
- Pages: with five records, `recordsOfAgent(id, 1, 2)` returns ids 2 and 3, and `recordsOfAgent(id, 5, 10)` returns an
  empty list.

## Reference Implementation

`AgentDefaultRegistry` accompanies this proposal with its tests. It keeps open and cured counts per reporter and
identity and per reporter and owner, and appends record ids to per-identity and per-owner lists.

## Security Considerations

- **False records.** Anyone can record a default about any identity or address. Readers MUST count only reporters they
  trust and SHOULD verify a reporter's records against its loans' own logs before trusting it.
- **Griefing an innocent owner.** A trusted reporter can be wrong or compromised. Readers should treat reporters'
  keys as lenders treat their own, and prefer reporters whose records can be checked against public loan logs.
- **Fresh addresses.** A defaulting owner can create a new address and a new identity. A count of zero means no default
  recorded by the listed reporters, not a vetted borrower.
- **Spam.** Listing functions are paginated because an identity's list can be made arbitrarily long. Counts do not
  depend on those lists.
- **Privacy.** Records hold only on-chain identifiers and amounts already public in the lender's own logs. Reporters
  MUST NOT put personal data in a loan reference.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
