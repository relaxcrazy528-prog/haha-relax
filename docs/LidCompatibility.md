# Closed-lid compatibility gate

Status: **not validated, unavailable in the app**. Battery-powered closed-lid operation remains required for the complete product. This preview implements the independently usable standard engine and the explicit capability boundary.

| Candidate | Evidence | Product decision |
| --- | --- | --- |
| Public `PreventUserIdleSystemSleep` | Scoped, process-owned, system timeout; ordinary idle sleep only | Shipping standard backend; not proof of lid prevention |
| `pmset disablesleep` | Persistent system-wide switch without per-app ownership; broad sleep gate | Excluded; no automatic fallback |
| Private assertion properties | Apple powerd checks dedicated entitlements for battery/lid properties | Not a normal third-party public capability |
| Root-domain selector 12 | Shared powerd bit; no demonstrated cleanup at `clientClose`; aggregate readback is insufficient | Research only; no shipping invocation |
| Recovery daemon/agent | Can improve availability of a compensating action, cannot manufacture ownership | No component installed without mechanism evidence |

Read-only local inventory:

```sh
python3 Research/inventory.py > Research/inventory/current.json
```

The inventory allowlists OS build, model family, architecture, CPU count, and three Boolean observations. It does not record serial numbers, usernames, MAC addresses, network names, or raw I/O registry output. Restricted hosts may return unknown; the tool does not guess or request elevated access.

A backend cannot pass the gate merely because an I/O call succeeds or `AppleClamshellCausesSleep` has a particular value. For each exact OS / hardware pair, record: real battery/no-external-display work continuity; manual sleep; normal exit; process hang; forced exit; observation latency; powerd restart behavior; competing tools; and protection-path scope. Validate low-battery/thermal policy using controlled inputs rather than deliberately creating a dangerous physical condition.

Apple GitHub `main` is research evidence, not a contract for this host's binaries:

- [IOPMLib public assertions and timeouts](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h)
- [Powerd property entitlement checks](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmconfigd/PMAssertions.c#L2326)
- [XNU sleep gating](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOPMrootDomain.cpp#L7098)
- [Root-domain user client lifecycle](https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/RootDomainUserClient.cpp#L250)
