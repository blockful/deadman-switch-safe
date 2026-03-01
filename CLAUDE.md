# Dead Man's Switch Safe

Gnosis Safe module + guard that transfers Safe ownership to an heir after inactivity.

## Build & Test

```bash
forge build
forge test -v                    # unit tests only
forge test --fork-url $RPC_URL   # includes fork tests (needs mainnet RPC)
forge fmt                        # format before committing
forge snapshot                   # update gas snapshot
```

## Architecture

- `src/DeadManSwitchModule.sol` — Safe module. Stores heir, delay, lastActivity. Executes takeover via `execTransactionFromModule`.
- `src/DeadManSwitchGuard.sol` — Safe guard. Calls `module.notifyActivity()` after every `execTransaction`. Never reverts.
- `test/DeadManSwitch.t.sol` — Unit tests with MockSafe.
- `test/DeadManSwitch.fork.t.sol` — Fork tests against real Safe v1.3.0 on mainnet.

## Conventions

- Solidity `^0.8.20`, Foundry toolchain
- `forge fmt` runs automatically before commits (via `.claude/hooks/`)
- PRs should be squash-merged into `main`
- Each fix/feature gets its own PR with a concise description

## Key Design Decisions

- Guard must never revert (uses low-level call to module)
- Guard checks `msg.sender == safe` to prevent third-party timer resets
- Module supports heir-is-already-owner takeover (removes other owners instead of reverting)
- Module auto-pauses after takeover to prevent reuse
- `execTransactionFromModule` calls bypass the guard — only `execTransaction` resets the timer
