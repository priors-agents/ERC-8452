# Agent Default Registry (draft ERC)

One contract where lenders record the defaults of their loans to agent identities, keyed by identity and by the owner
address the loan recorded. Any contract can then ask, inside the transaction that opens a line: how many open and cured
defaults does this identity, or this owner, have according to the lenders I trust? The cost of that question depends
only on the reader's own list of lenders, whatever anyone else records.

Identities are token ids of an ERC-721 identity registry, such as the Identity Registry of ERC-8004 (Trustless Agents).

**Status: draft, not submitted.** The text is in
[`ERCS/erc-draft_agent_default_registry.md`](ERCS/erc-draft_agent_default_registry.md). Its `eip: 99903` is a
placeholder: the ERC editors assign the real number when the pull request is opened on ethereum/ERCs. Discussion:
[Ethereum Magicians](https://ethereum-magicians.org/t/erc-tba-agent-default-registry/30026).

## Why

A default at one lender is invisible to the next: an agent, or its owner through another agent, borrows again elsewhere.
Lenders to ERC-8004 agents each keep their own marks (Priors per pool and per owner address, Nenrin as "scars"), and
reputation registries that average scores or keep one assertion per issuer cannot count defaults. This registry records
the fact itself, the loan that was not repaid, and lets each reader decide whose records it believes.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-draft_agent_default_registry.md` | The ERC text, in the ethereum/ERCs template |
| `src/IAgentDefaultRegistry.sol` | The interface |
| `src/AgentDefaultRegistry.sol` | A reference registry with per-reporter counts (not audited) |
| `test/AgentDefaultRegistry.t.sol` | Foundry tests, including counts that stay cheap after a reporter spams records |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- Agent Credit Lines: one interface to borrow, repay and default against any lender to agent identities
  (github.com/priors-agents/erc-agent-credit-lines). Its `Defaulted` event is what a lender records here.
- Credit history for ERC-8004 agents: a profile of the ERC-8004 Reputation Registry for loan outcomes
  (`docs/ERC-8004-CREDIT.md` in github.com/priors-agents/priors). Its `credit.defaulted` entries are the off-chain,
  rebuildable side of the same fact; this registry is the side a contract can read.

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
