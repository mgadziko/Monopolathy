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

    private let startingCash = 1_500
    private let dice: () -> (Int, Int)
    private var pendingExtraRoll = false

    init(dice: @escaping () -> (Int, Int) = { (Int.random(in: 1...6), Int.random(in: 1...6)) }) {
        self.dice = dice
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
            return player.inJailTurns > 0 ? [.payJailFine, .attemptJailRoll, .useGetOutOfJailFree] : [.rollDice]
        case .awaitingPurchase: return [.buyProperty, .declineProperty]
        case .trading: return [.endTurn]
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
            Player(id: UUID(), name: endpoint.displayName, kind: .ai, token: tokens[index], position: 0, cash: startingCash, properties: [], inJailTurns: 0, bankrupt: false)
        }
        currentPlayerIndex = 0
        phase = .awaitingRoll
        pendingAction = .none
        lastRoll = nil
        doublesThisTurn = 0
        pendingExtraRoll = false
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
        case .useGetOutOfJailFree: append("Get Out of Jail Free cards arrive with the official decks.")
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
            if let owner = owner(of: space.id), owner.id != playerID {
                transfer(amount: rentFor(space: space, ownerID: owner.id), from: playerID, to: owner.id)
                extraRoll ? beginExtraRoll() : endTurn()
            } else if owner == nil {
                pendingAction = .offerPurchase(spaceID: space.id, price: space.price)
                pendingExtraRoll = extraRoll
                phase = .awaitingPurchase
            } else { extraRoll ? beginExtraRoll() : endTurn() }
        case .chance, .communityChest:
            append("Official Chance and Community Chest decks are the next rules-engine milestone.")
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
        guard case let .offerPurchase(spaceID, _) = pendingAction else { return }
        append("\(currentPlayer?.name ?? "Player") declined \(board[spaceID].name). Auction support is pending.")
        pendingAction = .none
        pendingExtraRoll ? beginExtraRoll() : endTurn()
        pendingExtraRoll = false
    }

    private func payJailFine() {
        guard let player = currentPlayer else { return }
        charge(playerID: player.id, amount: 50, reason: "jail fine")
        guard var released = currentPlayer else { return }
        released.inJailTurns = 0
        update(released)
        append("\(released.name) paid $50 and left jail.")
    }

    private func beginExtraRoll() { phase = .awaitingRoll; append("\(currentPlayer?.name ?? "Player") rolls again.") }
    private func endTurn() { guard !players.isEmpty else { return }; doublesThisTurn = 0; currentPlayerIndex = (currentPlayerIndex + 1) % players.count; phase = .awaitingRoll; pendingAction = .none }
    private func charge(playerID: UUID, amount: Int, reason: String) { guard let index = players.firstIndex(where: { $0.id == playerID }) else { return }; players[index].cash -= amount; append("\(players[index].name) paid $\(amount) for \(reason).") }
    private func transfer(amount: Int, from payerID: UUID, to ownerID: UUID) { guard let payer = players.firstIndex(where: { $0.id == payerID }), let owner = players.firstIndex(where: { $0.id == ownerID }) else { return }; players[payer].cash -= amount; players[owner].cash += amount; append("\(players[payer].name) paid \(players[owner].name) $\(amount) rent.") }
    private func rentFor(space: BoardSpace, ownerID: UUID) -> Int { switch space.kind { case .railroad: let count = player(withID: ownerID)?.properties.filter { board[$0].kind == .railroad }.count ?? 0; return [25, 50, 100, 200][max(0, min(count - 1, 3))]; case .utility: let count = player(withID: ownerID)?.properties.filter { board[$0].kind == .utility }.count ?? 0; return (count == 2 ? 10 : 4) * ((lastRoll?.0 ?? 0) + (lastRoll?.1 ?? 0)); default: return space.rent } }
    private func sendToJail(playerID: UUID, reason: String) { guard var player = player(withID: playerID) else { return }; player.position = 10; player.inJailTurns = 1; update(player); append("\(player.name) went to jail (\(reason)).") }
    private func owner(of spaceID: Int) -> Player? { players.first { $0.properties.contains(spaceID) } }
    private func player(withID id: UUID) -> Player? { players.first { $0.id == id } }
    private func update(_ player: Player) { if let index = players.firstIndex(where: { $0.id == player.id }) { players[index] = player } }
    private func append(_ text: String) { log.insert(GameLogEntry(text: text), at: 0) }
}
