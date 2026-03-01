# Dead Man's Switch for Safe

Designate an heir for your [Safe](https://safe.global). If no transactions are executed within a configurable delay, the heir can claim full ownership.

```
  Safe owners sign transactions as usual
                    |
                    v
       +------------------------+
       |     DeadManSwitch      |
       |  (module + guard)      |
       +------------------------+
       |  checkAfterExecution() |-----> resets inactivity timer
       +------------------------+
                    |
                    | delay passes with no activity
                    v
       +------------------------+
       |  heir: triggerTakeover |
       +------------------------+
                    |
                    v
       Safe now has 1 owner: heir
       (threshold = 1, module paused)
```

## Architecture

A single contract acts as both a Safe **module** and **guard**:

- **Guard** -- `checkAfterExecution` resets the timer on every Safe transaction
- **Module** -- `triggerTakeover` uses `execTransactionFromModule` to swap owners

Deployed as **ERC-1167 minimal proxies** via `DeadManSwitchFactory` for cheap per-Safe clones.

## Setup

After deploying a clone through the factory, execute **2 Safe transactions**:

```
safe.enableModule(dms)
safe.setGuard(dms)
```

## Build & Test

```bash
forge build
forge test -vvv
forge test -vvv --fork-url $RPC_URL   # fork tests against mainnet Safe
```

## Deployment

```bash
# 1. Deploy factory (once per network)
forge script script/DeployFactory.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# 2. Create clone for your Safe
FACTORY_ADDRESS=0x... SAFE_ADDRESS=0x... HEIR_ADDRESS=0x... DELAY_SECONDS=2592000 \
  forge script script/DeployDeadManSwitch.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## License

MIT
