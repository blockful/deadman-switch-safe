# Dead Man's Switch Safe

A Gnosis Safe module that transfers Safe ownership to a designated heir after a period of inactivity.

## How it works

```
                          Safe (execTransaction)
                                 |
                                 v
                        DeadManSwitchGuard
                        (checkAfterExecution)
                                 |
                                 v
                        DeadManSwitchModule
                        (notifyActivity → resets timer)

    ... delay passes with no activity ...

                           Heir calls
                        triggerTakeover()
                                 |
                                 v
                      Module uses Safe's
                   execTransactionFromModule to:
                     1. Remove all other owners
                     2. Set threshold to 1
                     3. Heir becomes sole owner
```

**DeadManSwitchModule** is enabled as a Safe module. It stores the heir address, inactivity delay, and last activity timestamp. When the delay expires, the heir can call `triggerTakeover()` to become the sole owner.

**DeadManSwitchGuard** is set as the Safe's transaction guard. After every `execTransaction`, it calls `module.notifyActivity()` to reset the inactivity timer. It never reverts — a reverting guard would brick the Safe.

## Security model

- **Guard access control**: only the Safe itself can trigger activity recording (prevents third parties from resetting the timer)
- **Heir-is-owner support**: if the heir is already one of the Safe's owners, takeover removes the other owners instead of reverting
- **Auto-pause**: module pauses permanently after takeover to prevent reuse
- **Guard resilience**: guard uses low-level calls and never reverts, even if the module call fails

### Limitations

- `execTransactionFromModule` (calls from other modules) **bypass the guard**. If other modules are enabled, their activity won't reset the timer unless they explicitly call `ping()`
- The module is powerful by design — it can change owners. Treat it as a time-locked root key
- No upgrade mechanism. If a bug is found, owners must disable the module and deploy a new one
- Block timestamp manipulation exists (~12s on Ethereum) but is negligible for delays measured in days

## Deployment

```bash
forge script script/DeadManSwitch.s.sol:DeadManSwitchScript \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Environment variables:
- `SAFE_ADDRESS` — the Gnosis Safe to protect
- `HEIR_ADDRESS` — address that can trigger takeover
- `DELAY_SECONDS` — inactivity period before takeover is allowed

After deployment, execute these Safe transactions (requires owner signatures):

1. Enable the module: `safe.enableModule(module)`
2. Set the guard on the Safe: `safe.setGuard(guard)`
3. Set the guard in the module: `module.setGuard(guard)`

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
