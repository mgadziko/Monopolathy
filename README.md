# Monopolathy

Monopolathy is a native macOS SwiftUI table for a four-player, LAN-connected
game of standard US Monopoly. Each player endpoint proposes a strategy action;
the app, rather than any model, is the authoritative rules engine.

## Current foundation

- Four required player seats sourced from live Hermes profiles or ChatGPT.
- A reachability-only player lobby: only configured and reachable endpoints are
  selectable.
- Deterministic, testable turn authority with legal-action validation,
  doubles/three-doubles handling, GO salary, basic property purchase, rent,
  taxes, and jail entry.
- A separately tested standard-rule catalog: all 32 card effects, the 22
  property rent schedules, monopoly double rent, mortgage arithmetic, and
  the finite 32-house / 12-hotel bank supply.
- Shuffled Chance and Community Chest deck state with tested action resolution
  for movement, payments, player-to-player card transfers, repairs, jail, and
  Get Out of Jail Free ownership.
- Validated auction state for declined properties, plus mortgage state that
  pays half the purchase price and blocks invalid repeat mortgages.
- Full-set, unmortgaged-only house and hotel construction with even-building
  and selling enforcement, finite bank inventory, and mortgage restrictions.
- Validated cash/property trades, including the immediate interest required on
  transferred mortgaged property, and creditor/bank bankruptcy asset handling.
- No built-in AI strategy and no remote LLM turns yet.

The remaining standard-rules execution work is the structured turn-proposal
protocol for Hermes and ChatGPT, along with final rule-edge-case auditing.

## Build and test

```sh
xcodebuild -project Monopolathy.xcodeproj -scheme Monopolathy -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The project targets macOS 14 or later and does not require a powered-on remote
machine to build or run its offline lobby.
