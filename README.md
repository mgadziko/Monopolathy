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
  taxes, and standard jail release rules.
- A separately tested standard-rule catalog: all 32 card effects, the 22
  property rent schedules, monopoly double rent, mortgage arithmetic, and
  the finite 32-house / 12-hotel bank supply.
- Shuffled Chance and Community Chest deck state with tested action resolution
  for movement, payments, player-to-player card transfers, repairs, jail, and
  Get Out of Jail Free ownership. Card-directed movement resolves its
  destination normally, including purchase decisions, chained card spaces,
  double railroad rent, and the utility card's fresh rent roll.
- A held Get Out of Jail Free card is removed from its originating deck and is
  returned only when used or when its holder leaves the game.
- Validated auction state for declined properties, plus mortgage state that
  pays half the purchase price, suppresses rent, and blocks invalid repeat mortgages. Auctions
  follow the standard rule that the player who declined the property may still
  bid.
- Full-set, unmortgaged-only house and hotel construction with even-building
  and selling enforcement, finite bank inventory, and mortgage restrictions.
- Before each turn, the player endpoint may make validated asset-management
  decisions—build, sell a building, mortgage, or unmortgage—until it replies
  that it is finished. The app never chooses those actions for it.
- If a payment makes a player insolvent, play pauses for that player to sell
  buildings, mortgage eligible property, or make one exact trade offer. Only when it replies that it is
  finished does the engine either resume the interrupted turn or process a
  standard bankruptcy; it never eliminates a player merely for a temporary
  negative balance.
- Validated cash/property trades, including the immediate interest required on
  transferred mortgaged property, and creditor/bank bankruptcy asset handling.
  A creditor inheriting a mortgaged property through bankruptcy likewise pays
  the standard immediate 10% mortgage interest to the Bank.
- If a player owes the Bank and goes bankrupt, their returned properties are
  automatically auctioned to the remaining players before normal turn flow
  resumes; a mortgage on a returned property is cleared by its return.
  Once per turn, a player may make one exact offer; its recipient separately
  accepts or declines that validated offer.
- Bankruptcy removes the player from turn rotation; the engine records a
  game-over winner when only one solvent player remains.
- A strict, JSON-only turn-proposal protocol: endpoints receive a table
  snapshot and their current legal actions; malformed or illegal proposals are
  rejected before they can touch game state.
- A tested turn coordinator that keeps network transports separate from the
  rules engine; transports return text only and cannot invoke game tools.
- A narrow Hermes turn transport reads the selected profile's configured model
  endpoint and sends it only the current JSON turn prompt. It cannot use
  Hermes tools, terminals, memories, or alter the rules engine directly.
- Starting a game begins unthrottled automatic play: each active Hermes player
  receives one strict turn request at a time and the next request is made as
  soon as its legal action resolves. **Stop Automatic Play** and **Ask Current
  Player** remain available controls. Auctions use a separate strict `bid` or
  `pass` JSON proposal per eligible player, and therefore continue
  automatically. The optional trade window uses a separate proposal followed
  by an exact-offer acceptance, so automatic play continues afterward.
- The live table includes a complete board view: player tokens move around the
  standard 40 spaces. Its central live scoreboard keeps the current phase,
  player, player-color key, cash, locations, and last roll visible, while the
  side panel retains the chronological table log. Select a board space to
  inspect its price, owner, mortgage state, and development.
- No built-in AI strategy and no ChatGPT connection yet.

The remaining work is a user-authorized ChatGPT sign-in flow and continued
rule-edge-case auditing. No endpoint will receive general tool access.

## Build and test

```sh
xcodebuild -project Monopolathy.xcodeproj -scheme Monopolathy -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The project targets macOS 14 or later and does not require a powered-on remote
machine to build or run its offline lobby.

## App bundle

A freshly built Debug bundle is available at `dist/Monopolathy.app`. It is a
copyable local artifact; rebuild it with the Debug scheme before distributing a
newer version.
