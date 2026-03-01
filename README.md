# Dead Man's Switch Safe

A Gnosis Safe module + guard that transfers Safe ownership to a designated heir after a period of inactivity. Deployable as cheap ERC-1167 minimal proxy clones.

## How it works

```
                          Safe (execTransaction)
                                 |
                                 v
                           DeadManSwitch
                      (checkAfterExecution → resets timer)

    ... delay passes with no activity ...

                           Heir calls
                        triggerTakeover()
                                 |
                                 v
                    DeadManSwitch uses Safe's
                   execTransactionFromModule to:
                     1. Remove all other owners
                     2. Set threshold to 1
                     3. Heir becomes sole owner
```

**DeadManSwitch** is a single contract that serves as both a Safe module and a Safe guard. After every `execTransaction`, its `checkAfterExecution` hook resets the inactivity timer. When the delay expires, the heir can call `triggerTakeover()` to become the sole owner.

**DeadManSwitchFactory** deploys ERC-1167 minimal proxy clones (~45 bytes each) via CREATE2, making per-Safe deployment cheap and deterministic.

## Security model

- **Guard access control**: only the Safe itself triggers activity recording (prevents third parties from resetting the timer)
- **Heir-is-owner support**: if the heir is already one of the Safe's owners, takeover removes the other owners instead of reverting
- **Auto-pause**: module pauses permanently after takeover to prevent reuse
- **Guard resilience**: `checkAfterExecution` silently ignores non-Safe callers and never reverts

### Limitations

- `execTransactionFromModule` (calls from other modules) **bypass the guard**. If other modules are enabled, their activity won't reset the timer unless they explicitly call `ping()`
- The module is powerful by design — it can change owners. Treat it as a time-locked root key
- No upgrade mechanism. If a bug is found, owners must disable the module and deploy a new one
- Block timestamp manipulation exists (~12s on Ethereum) but is negligible for delays measured in days

## Deployment

### 1. Deploy factory (one-time per network)

```bash
forge script script/DeadManSwitch.s.sol:DeployFactory \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### 2. Create clone for a Safe

```bash
FACTORY_ADDRESS=0x... \
SAFE_ADDRESS=0x... \
HEIR_ADDRESS=0x... \
DELAY_SECONDS=2592000 \
forge script script/DeadManSwitch.s.sol:DeployDeadManSwitch \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### 3. Wire up (2 Safe transactions)

After deployment, execute these Safe transactions (requires owner signatures):

1. Enable as module: `safe.enableModule(dms)`
2. Set as guard: `safe.setGuard(dms)`

## Build & Test

```bash
forge build
forge test -v                                           # unit tests
forge test --fork-url $RPC_URL -v                       # includes fork tests
forge fmt                                               # format
forge snapshot                                          # gas snapshot
```

## License

LGPL-3.0-only
