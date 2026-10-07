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
- A strict, JSON-only turn-proposal protocol: endpoints receive a table
  snapshot and their current legal actions; malformed or illegal proposals are
  rejected before they can touch game state.
- A tested turn coordinator that keeps network transports separate from the
  rules engine; transports return text only and cannot invoke game tools.
- A narrow Hermes turn transport reads the selected profile's configured model
  endpoint and sends it only the current JSON turn prompt. It cannot use
  Hermes tools, terminals, memories, or alter the rules engine directly.
- At the table, **Ask Current Player** makes one live, validated decision for
  the active Hermes player. This deliberately pauses for auctions and trades
  until their multi-player proposal protocol is complete.
- No built-in AI strategy and no ChatGPT connection yet.

The remaining work is a user-authorized ChatGPT sign-in flow, auction/trade
proposal protocols, continuous play controls, and final rule-edge-case
auditing. No endpoint will receive general tool access.

## Build and test

```sh
xcodebuild -project Monopolathy.xcodeproj -scheme Monopolathy -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The project targets macOS 14 or later and does not require a powered-on remote
machine to build or run its offline lobby.
