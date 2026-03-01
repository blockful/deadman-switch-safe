# Dead Man's Switch for Safe

Designate an heir for your [Safe](https://safe.global). If the Safe owners stop signing transactions for a configurable period, the heir can claim full ownership.

```
  Safe owners sign transactions as usual
        (proof of life / check-in)
                    |
                    v
       +------------------------+
       |     DeadManSwitch      |
       |    (module + guard)    |
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

## How It Works

A single contract acts as both a Safe **module** and **guard**:

- **Guard** -- `checkAfterExecution` resets the timer after every `execTransaction` call. Only direct Safe transactions reset the timer -- calls from other modules (`execTransactionFromModule`) bypass the guard and do **not** count as activity.
- **Module** -- `triggerTakeover` uses `execTransactionFromModule` to remove all existing owners and make the heir the sole owner.
- **Manual check-in** -- Safe owners can call `ping()` via a Safe transaction to reset the timer without performing any other action. Useful if other modules are enabled whose activity won't be detected by the guard.

Deployed as **ERC-1167 minimal proxies** via `DeadManSwitchFactory` for cheap, deterministic per-Safe clones.

## Setup

After deploying a clone through the factory, execute **2 Safe transactions**:

```
safe.enableModule(deadManSwitch)
safe.setGuard(deadManSwitch)
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
