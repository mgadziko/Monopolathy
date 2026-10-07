import Foundation

/// The authority for the table. Player endpoints submit one action; this
/// engine alone decides whether that action is legal and applies it.
@MainActor
final class GameEngine: ObservableObject {
    @Published private(set) var board = BoardSpace.standardBoard
    @Published private(set) var players: [Player] = []
    @Published private(set) var currentPlayerIndex = 0
    @Published private(set) var phase: TurnPhase = .awaitingRoll
    @Published private(set) var pendingAction: PendingAction = .none
    @Published private(set) var lastRoll: (Int, Int)?
    @Published private(set) var log: [GameLogEntry] = []
    @Published private(set) var doublesThisTurn = 0
    @Published private(set) var buildingsBySpaceID: [Int: Int] = [:]
    @Published private(set) var mortgagedSpaceIDs: Set<Int> = []
    @Published private(set) var auction: AuctionState?

    private let startingCash = 1_500
    private let dice: () -> (Int, Int)
    private let deckOrder: [MonopolyCard]?
    private var pendingExtraRoll = false
    private var chanceCards: [MonopolyCard] = []
    private var communityChestCards: [MonopolyCard] = []

    init(dice: @escaping () -> (Int, Int) = { (Int.random(in: 1...6), Int.random(in: 1...6)) }, deckOrder: [MonopolyCard]? = nil) {
        self.dice = dice
        self.deckOrder = deckOrder
    }

    var currentPlayer: Player? {
        players.indices.contains(currentPlayerIndex) ? players[currentPlayerIndex] : nil
    }

    var ownerBySpaceID: [Int: Player] {
        Dictionary(uniqueKeysWithValues: players.flatMap { player in player.properties.map { ($0, player) } })
    }

    var legalActions: [GameAction] {
        guard let player = currentPlayer, !player.bankrupt else { return [] }
        switch phase {
        case .awaitingRoll:
            if player.inJailTurns > 0 {
                var actions: [GameAction] = [.payJailFine, .attemptJailRoll]
                if player.getOutOfJailFreeCards > 0 { actions.append(.useGetOutOfJailFree) }
                return actions
            }
            return [.rollDice]
        case .awaitingPurchase: return [.buyProperty, .declineProperty]
        case .trading, .auction: return []
        case .resolvingAI, .gameOver: return []
        }
    }

    func start(endpoints: [PlayerEndpoint]) {
        let unique = Array(Set(endpoints)).sorted { $0.rawValue < $1.rawValue }
        guard unique.count == 4 else {
            append("Choose four distinct, reachable players before starting.")
            return
        }
        let tokens = ["car", "hat", "dog", "ship"]
        players = unique.enumerated().map { index, endpoint in
            Player(id: UUID(), name: endpoint.displayName, kind: .ai, token: tokens[index], position: 0, cash: startingCash, properties: [], inJailTurns: 0, getOutOfJailFreeCards: 0, bankrupt: false)
        }
        currentPlayerIndex = 0
        phase = .awaitingRoll
        pendingAction = .none
        lastRoll = nil
        doublesThisTurn = 0
        pendingExtraRoll = false
        buildingsBySpaceID = [:]
        mortgagedSpaceIDs = []
        auction = nil
        chanceCards = (deckOrder ?? MonopolyCard.standardDeck).filter { $0.deck == .chance }
        communityChestCards = (deckOrder ?? MonopolyCard.standardDeck).filter { $0.deck == .communityChest }
        if deckOrder == nil { chanceCards.shuffle(); communityChestCards.shuffle() }
        log = [GameLogEntry(text: "Standard-rules game started with four players.")]
    }

    func returnToLobby() {
        players = []
        currentPlayerIndex = 0
        phase = .awaitingRoll
        pendingAction = .none
        lastRoll = nil
        doublesThisTurn = 0
        pendingExtraRoll = false
        buildingsBySpaceID = [:]
        mortgagedSpaceIDs = []
        auction = nil
        log = []
    }

    /// Entry point for the local controls and, later, a structured LLM reply.
    @discardableResult
    func submit(_ action: GameAction) -> Bool {
        guard legalActions.contains(action) else {
            append("Rejected illegal action: \(String(describing: action)).")
            return false
        }
        switch action {
        case .rollDice, .attemptJailRoll: rollDice()
        case .buyProperty: buyPendingProperty()
        case .declineProperty: declinePendingProperty()
        case .payJailFine: payJailFine()
        case .useGetOutOfJailFree: useGetOutOfJailFree()
        case .endTurn: endTurn()
        }
        return true
    }

    private func rollDice() {
        guard var player = currentPlayer else { return }
        let roll = dice()
        lastRoll = roll
        let doubles = roll.0 == roll.1

        if player.inJailTurns > 0 {
            guard doubles else {
                player.inJailTurns += 1
                update(player)
                append("\(player.name) did not roll doubles in jail.")
                endTurn()
                return
            }
            player.inJailTurns = 0
            update(player)
            append("\(player.name) rolled doubles and left jail.")
        }

        doublesThisTurn = doubles ? doublesThisTurn + 1 : 0
        if doublesThisTurn == 3 {
            sendToJail(playerID: player.id, reason: "three consecutive doubles")
            endTurn()
            return
        }

        move(playerID: player.id, by: roll.0 + roll.1)
        resolveLanding(for: player.id, extraRoll: doubles)
    }

    private func move(playerID: UUID, by spaces: Int) {
        guard var player = player(withID: playerID) else { return }
        let prior = player.position
        player.position = (player.position + spaces) % board.count
        if prior + spaces >= board.count { player.cash += 200; append("\(player.name) passed GO and collected $200.") }
        update(player)
        append("\(player.name) rolled \(lastRoll?.0 ?? 0)+\(lastRoll?.1 ?? 0) and landed on \(board[player.position].name).")
    }

    private func resolveLanding(for playerID: UUID, extraRoll: Bool) {
        guard let player = player(withID: playerID) else { return }
        let space = board[player.position]
        switch space.kind {
        case .go, .jail, .freeParking: extraRoll ? beginExtraRoll() : endTurn()
        case .goToJail: sendToJail(playerID: playerID, reason: "Go To Jail"); endTurn()
        case .tax: charge(playerID: playerID, amount: space.tax, reason: space.name); extraRoll ? beginExtraRoll() : endTurn()
        case .property, .railroad, .utility:
            let spaceOwner = owner(of: space.id)
            if let spaceOwner, spaceOwner.id != playerID {
                transfer(amount: rentFor(space: space, ownerID: spaceOwner.id), from: playerID, to: spaceOwner.id)
                extraRoll ? beginExtraRoll() : endTurn()
            } else if spaceOwner == nil {
                pendingAction = .offerPurchase(spaceID: space.id, price: space.price)
                pendingExtraRoll = extraRoll
                phase = .awaitingPurchase
            } else { extraRoll ? beginExtraRoll() : endTurn() }
        case .chance:
            drawCard(from: .chance, for: playerID)
            extraRoll ? beginExtraRoll() : endTurn()
        case .communityChest:
            drawCard(from: .communityChest, for: playerID)
            extraRoll ? beginExtraRoll() : endTurn()
        }
    }

    private func buyPendingProperty() {
        guard case let .offerPurchase(spaceID, price) = pendingAction, let index = players.indices.contains(currentPlayerIndex) ? currentPlayerIndex : nil, players[index].cash >= price else { return }
        players[index].cash -= price
        players[index].properties.insert(spaceID)
        append("\(players[index].name) bought \(board[spaceID].name) for $\(price).")
        pendingAction = .none
        pendingExtraRoll ? beginExtraRoll() : endTurn()
        pendingExtraRoll = false
    }

    private func declinePendingProperty() {
        guard case let .offerPurchase(spaceID, _) = pendingAction, let player = currentPlayer else { return }
        append("\(player.name) declined \(board[spaceID].name). Auction opened.")
        pendingAction = .none
        auction = AuctionState(spaceID: spaceID, excludedPlayerID: player.id, leadingBidderID: nil, leadingBid: 0, passedPlayerIDs: [player.id])
        phase = .auction
    }

    @discardableResult
    func placeAuctionBid(_ amount: Int, by playerID: UUID) -> Bool {
        guard var auction, let bidder = player(withID: playerID), !bidder.bankrupt,
              playerID != auction.excludedPlayerID, !auction.passedPlayerIDs.contains(playerID),
              amount > auction.leadingBid, amount <= bidder.cash else { return false }
        auction.leadingBidderID = playerID
        auction.leadingBid = amount
        self.auction = auction
        append("\(bidder.name) bid $\(amount) for \(board[auction.spaceID].name).")
        return true
    }

    @discardableResult
    func passAuction(by playerID: UUID) -> Bool {
        guard var auction, playerID != auction.leadingBidderID else { return false }
        auction.passedPlayerIDs.insert(playerID)
        let remaining = players.filter { !$0.bankrupt && $0.id != auction.excludedPlayerID && $0.id != auction.leadingBidderID && !auction.passedPlayerIDs.contains($0.id) }
        if remaining.isEmpty {
            if let winnerID = auction.leadingBidderID, let index = players.firstIndex(where: { $0.id == winnerID }) {
                players[index].cash -= auction.leadingBid
                players[index].properties.insert(auction.spaceID)
                append("\(players[index].name) won \(board[auction.spaceID].name) for $\(auction.leadingBid).")
            } else { append("No bids for \(board[auction.spaceID].name).") }
            self.auction = nil
            pendingExtraRoll ? beginExtraRoll() : endTurn()
            pendingExtraRoll = false
        } else { self.auction = auction }
        return true
    }

    @discardableResult
    func mortgage(spaceID: Int, by playerID: UUID) -> Bool {
        guard let player = player(withID: playerID), player.properties.contains(spaceID),
              board[spaceID].isPurchasable, !mortgagedSpaceIDs.contains(spaceID),
              buildingsBySpaceID[spaceID, default: 0] == 0 else { return false }
        let group = StandardRules.colorSet(for: spaceID)
        guard group.allSatisfy({ buildingsBySpaceID[$0, default: 0] == 0 }), let index = players.firstIndex(where: { $0.id == playerID }) else { return false }
        players[index].cash += StandardRules.mortgageValue(for: board[spaceID])
        mortgagedSpaceIDs.insert(spaceID)
        append("\(players[index].name) mortgaged \(board[spaceID].name).")
        return true
    }

    private func payJailFine() {
        guard let player = currentPlayer else { return }
        charge(playerID: player.id, amount: 50, reason: "jail fine")
        guard var released = currentPlayer else { return }
        released.inJailTurns = 0
        update(released)
        append("\(released.name) paid $50 and left jail.")
    }

    private func useGetOutOfJailFree() {
        guard var player = currentPlayer, player.getOutOfJailFreeCards > 0 else { return }
        player.getOutOfJailFreeCards -= 1
        player.inJailTurns = 0
        update(player)
        append("\(player.name) used a Get Out of Jail Free card.")
    }

    private func drawCard(from deck: CardDeck, for playerID: UUID) {
        var cards = deck == .chance ? chanceCards : communityChestCards
        guard !cards.isEmpty else { return }
        let card = cards.removeFirst()
        cards.append(card)
        if deck == .chance { chanceCards = cards } else { communityChestCards = cards }
        append("\(deck == .chance ? "Chance" : "Community Chest") card: \(card.id).")
        resolve(card.effect, for: playerID)
    }

    private func resolve(_ effect: CardEffect, for playerID: UUID) {
        guard let player = player(withID: playerID) else { return }
        switch effect {
        case let .moveTo(destination, collectGo):
            var moved = player
            if collectGo && destination < moved.position { moved.cash += StandardRules.goSalary }
            moved.position = destination
            update(moved)
            append("\(moved.name) moved to \(board[destination].name).")
        case let .moveBack(spaces):
            var moved = player
            moved.position = (moved.position - spaces + board.count) % board.count
            update(moved)
            append("\(moved.name) moved back \(spaces) spaces.")
        case .nearestRailroad:
            let railroads = [5, 15, 25, 35]
            let destination = railroads.first(where: { $0 > player.position }) ?? 5
            var moved = player
            if destination < moved.position { moved.cash += StandardRules.goSalary }
            moved.position = destination
            update(moved)
            append("\(moved.name) advanced to the nearest railroad.")
        case .nearestUtility:
            let destination = [12, 28].first(where: { $0 > player.position }) ?? 12
            var moved = player
            if destination < moved.position { moved.cash += StandardRules.goSalary }
            moved.position = destination
            update(moved)
            append("\(moved.name) advanced to the nearest utility.")
        case let .collect(amount):
            var updated = player; updated.cash += amount; update(updated); append("\(updated.name) collected $\(amount).")
        case let .payBank(amount): charge(playerID: playerID, amount: amount, reason: "card")
        case let .payEachPlayer(amount):
            for recipient in players where recipient.id != playerID && !recipient.bankrupt { transfer(amount: amount, from: playerID, to: recipient.id) }
        case let .collectFromEachPlayer(amount):
            for payer in players where payer.id != playerID && !payer.bankrupt { transfer(amount: amount, from: payer.id, to: playerID) }
        case .goToJail: sendToJail(playerID: playerID, reason: "card")
        case .getOutOfJailFree:
            var updated = player; updated.getOutOfJailFreeCards += 1; update(updated); append("\(updated.name) received a Get Out of Jail Free card.")
        case let .propertyRepairs(perHouse, perHotel):
            let amount = player.properties.reduce(0) { partial, spaceID in
                let buildings = buildingsBySpaceID[spaceID, default: 0]
                return partial + (buildings == 5 ? perHotel : buildings * perHouse)
            }
            if amount > 0 { charge(playerID: playerID, amount: amount, reason: "property repairs") }
        }
    }

    private func beginExtraRoll() { phase = .awaitingRoll; append("\(currentPlayer?.name ?? "Player") rolls again.") }
    private func endTurn() { guard !players.isEmpty else { return }; doublesThisTurn = 0; currentPlayerIndex = (currentPlayerIndex + 1) % players.count; phase = .awaitingRoll; pendingAction = .none }
    private func charge(playerID: UUID, amount: Int, reason: String) { guard let index = players.firstIndex(where: { $0.id == playerID }) else { return }; players[index].cash -= amount; append("\(players[index].name) paid $\(amount) for \(reason).") }
    private func transfer(amount: Int, from payerID: UUID, to ownerID: UUID) { guard let payer = players.firstIndex(where: { $0.id == payerID }), let owner = players.firstIndex(where: { $0.id == ownerID }) else { return }; players[payer].cash -= amount; players[owner].cash += amount; append("\(players[payer].name) paid \(players[owner].name) $\(amount) rent.") }
    private func rentFor(space: BoardSpace, ownerID: UUID) -> Int { switch space.kind { case .railroad: let count = player(withID: ownerID)?.properties.filter { board[$0].kind == .railroad }.count ?? 0; return [25, 50, 100, 200][max(0, min(count - 1, 3))]; case .utility: let count = player(withID: ownerID)?.properties.filter { board[$0].kind == .utility }.count ?? 0; return (count == 2 ? 10 : 4) * ((lastRoll?.0 ?? 0) + (lastRoll?.1 ?? 0)); case .property: let set = StandardRules.colorSet(for: space.id); let ownsSet = set.isSubset(of: player(withID: ownerID)?.properties ?? []); return StandardRules.baseRent(spaceID: space.id, buildings: buildingsBySpaceID[space.id, default: 0], ownsColorSet: ownsSet); default: return space.rent } }
    private func sendToJail(playerID: UUID, reason: String) { guard var player = player(withID: playerID) else { return }; player.position = 10; player.inJailTurns = 1; update(player); append("\(player.name) went to jail (\(reason)).") }
    private func owner(of spaceID: Int) -> Player? { players.first { $0.properties.contains(spaceID) } }
    private func player(withID id: UUID) -> Player? { players.first { $0.id == id } }
    private func update(_ player: Player) { if let index = players.firstIndex(where: { $0.id == player.id }) { players[index] = player } }
    private func append(_ text: String) { log.insert(GameLogEntry(text: text), at: 0) }
}
