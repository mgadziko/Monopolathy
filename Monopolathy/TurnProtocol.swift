import Foundation

struct TurnSnapshot: Codable, Equatable {
    struct PlayerState: Codable, Equatable, Identifiable {
        let id: UUID
        let name: String
        let cash: Int
        let position: Int
        let properties: [Int]
        let bankrupt: Bool
    }

    let currentPlayerID: UUID
    let currentPlayerName: String
    let phase: String
    let lastRoll: [Int]?
    let players: [PlayerState]
    let legalActions: [String]

    @MainActor init(engine: GameEngine) {
        currentPlayerID = engine.currentPlayer?.id ?? UUID()
        currentPlayerName = engine.currentPlayer?.name ?? ""
        phase = engine.phase.rawValue
        lastRoll = engine.lastRoll.map { [$0.0, $0.1] }
        players = engine.players.map { .init(id: $0.id, name: $0.name, cash: $0.cash, position: $0.position, properties: $0.properties.sorted(), bankrupt: $0.bankrupt) }
        legalActions = engine.legalActions.map(TurnProtocol.name(for:))
    }
}

private struct ProposedAction: Decodable { let action: String }

enum TurnProtocolError: LocalizedError, Equatable {
    case malformedReply
    case illegalAction(String)

    var errorDescription: String? {
        switch self {
        case .malformedReply: "The player response was not a JSON action object."
        case let .illegalAction(action): "The proposed action is not legal now: \(action)."
        }
    }
}

enum TurnProtocol {
    static func name(for action: GameAction) -> String {
        switch action {
        case .rollDice: "roll_dice"
        case .buyProperty: "buy_property"
        case .declineProperty: "decline_property"
        case .payJailFine: "pay_jail_fine"
        case .useGetOutOfJailFree: "use_get_out_of_jail_free"
        case .attemptJailRoll: "attempt_jail_roll"
        case .endTurn: "end_turn"
        }
    }

    static func prompt(for snapshot: TurnSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let state = String(data: (try? encoder.encode(snapshot)) ?? Data(), encoding: .utf8) ?? "{}"
        return """
        You are \(snapshot.currentPlayerName), playing a standard-rules Monopoly game. Decide strategy yourself, but never invent a game action.

        Table state JSON:
        \(state)

        Reply with exactly one JSON object and no Markdown or explanation:
        {"action":"one_of_the_legal_actions"}
        """
    }

    static func action(from reply: String, allowed: [GameAction]) throws -> GameAction {
        guard let proposal = try? JSONDecoder().decode(ProposedAction.self, from: Data(reply.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) else { throw TurnProtocolError.malformedReply }
        let named = Dictionary(uniqueKeysWithValues: allowed.map { (name(for: $0), $0) })
        guard let action = named[proposal.action] else { throw TurnProtocolError.illegalAction(proposal.action) }
        return action
    }
}

/// Implementations may call a selected Hermes backend or a connected ChatGPT
/// plan. They return text only; they never receive permission to alter game
/// state or invoke tools.
protocol PlayerTurnTransport: Sendable {
    func respond(to prompt: String) async throws -> String
}

enum TurnCoordinatorError: LocalizedError {
    case proposalRejected(TurnProtocolError)
    case engineRejected

    var errorDescription: String? {
        switch self {
        case let .proposalRejected(error): error.errorDescription
        case .engineRejected: "The engine rejected an otherwise parsed action."
        }
    }
}

@MainActor
final class TurnCoordinator {
    func playTurn(engine: GameEngine, transport: any PlayerTurnTransport) async throws -> GameAction {
        let snapshot = TurnSnapshot(engine: engine)
        let reply = try await transport.respond(to: TurnProtocol.prompt(for: snapshot))
        do {
            let action = try TurnProtocol.action(from: reply, allowed: engine.legalActions)
            guard engine.submit(action) else { throw TurnCoordinatorError.engineRejected }
            return action
        } catch let error as TurnProtocolError {
            throw TurnCoordinatorError.proposalRejected(error)
        }
    }
}

struct AuctionSnapshot: Codable, Equatable {
    let playerID: UUID
    let playerName: String
    let playerCash: Int
    let propertyName: String
    let currentBid: Int
    let leadingBidderName: String?
    let minimumBid: Int

    @MainActor init(engine: GameEngine, bidder: Player) {
        let auction = engine.auction!
        playerID = bidder.id
        playerName = bidder.name
        playerCash = bidder.cash
        propertyName = engine.board[auction.spaceID].name
        currentBid = auction.leadingBid
        leadingBidderName = auction.leadingBidderID.flatMap { id in engine.players.first(where: { $0.id == id })?.name }
        minimumBid = auction.leadingBid + 1
    }
}

enum AuctionDecision: Equatable {
    case bid(Int)
    case pass
}

private struct ProposedAuctionAction: Decodable {
    let action: String
    let amount: Int?
}

enum AuctionProtocolError: LocalizedError, Equatable {
    case malformedReply
    case illegalAction(String)

    var errorDescription: String? {
        switch self {
        case .malformedReply: "The auction response was not a valid JSON bid or pass object."
        case let .illegalAction(action): "The auction proposal is not legal now: \(action)."
        }
    }
}

enum AuctionProtocol {
    static func prompt(for snapshot: AuctionSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let state = String(data: (try? encoder.encode(snapshot)) ?? Data(), encoding: .utf8) ?? "{}"
        return """
        You are \(snapshot.playerName), participating in a standard-rules Monopoly auction. Decide strategy yourself. You may bid any whole-dollar amount from \(snapshot.minimumBid) through \(snapshot.playerCash), or pass permanently. Do not invent other actions.

        Auction state JSON:
        \(state)

        Reply with exactly one JSON object and no Markdown or explanation:
        {"action":"bid","amount":whole_dollar_amount}
        or
        {"action":"pass"}
        """
    }

    static func decision(from reply: String, minimumBid: Int, availableCash: Int) throws -> AuctionDecision {
        guard let proposal = try? JSONDecoder().decode(ProposedAuctionAction.self, from: Data(reply.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) else { throw AuctionProtocolError.malformedReply }
        switch proposal.action {
        case "pass": return .pass
        case "bid":
            guard let amount = proposal.amount, amount >= minimumBid, amount <= availableCash else { throw AuctionProtocolError.illegalAction("bid") }
            return .bid(amount)
        default: throw AuctionProtocolError.illegalAction(proposal.action)
        }
    }
}

enum AuctionCoordinatorError: LocalizedError {
    case proposalRejected(AuctionProtocolError)
    case engineRejected

    var errorDescription: String? {
        switch self {
        case let .proposalRejected(error): error.errorDescription
        case .engineRejected: "The engine rejected an otherwise parsed auction proposal."
        }
    }
}

@MainActor
final class AuctionCoordinator {
    func requestAuctionDecision(engine: GameEngine, bidder: Player, transport: any PlayerTurnTransport) async throws -> AuctionDecision {
        guard let auction = engine.auction else { throw AuctionCoordinatorError.engineRejected }
        let snapshot = AuctionSnapshot(engine: engine, bidder: bidder)
        let reply = try await transport.respond(to: AuctionProtocol.prompt(for: snapshot))
        do {
            let decision = try AuctionProtocol.decision(from: reply, minimumBid: auction.leadingBid + 1, availableCash: bidder.cash)
            let applied: Bool
            switch decision {
            case let .bid(amount): applied = engine.placeAuctionBid(amount, by: bidder.id)
            case .pass: applied = engine.passAuction(by: bidder.id)
            }
            guard applied else { throw AuctionCoordinatorError.engineRejected }
            return decision
        } catch let error as AuctionProtocolError {
            throw AuctionCoordinatorError.proposalRejected(error)
        }
    }
}

enum HermesTurnTransportError: LocalizedError {
    case profileUnavailable
    case invalidResponse

    var errorDescription: String? { self == .profileUnavailable ? "The selected Hermes profile is unavailable." : "The Hermes model returned no usable response." }
}

/// A deliberately narrow adapter for Triopathy-compatible Hermes profiles.
/// It sends exactly one prompt to the selected model endpoint; it does not run
/// Hermes tools, sessions, memory, or terminal workflows.
struct HermesTurnTransport: PlayerTurnTransport {
    let endpoint: PlayerEndpoint

    func respond(to prompt: String) async throws -> String {
        guard let profile = endpoint.hermesProfileName,
              let text = try? String(contentsOf: URL(fileURLWithPath: NSString(string: "~/.hermes/profiles/\(profile)/config.yaml").expandingTildeInPath)),
              let backend = Self.selectedBackend(in: text) else { throw HermesTurnTransportError.profileUnavailable }
        var url = backend.api
        url.appendPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: backend.model, messages: [.init(role: "user", content: prompt)], maxTokens: 128, temperature: 0))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let reply = try? JSONDecoder().decode(Response.self, from: data).choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { throw HermesTurnTransportError.invalidResponse }
        return reply
    }

    private static func selectedBackend(in text: String) -> (api: URL, model: String)? {
        let lines = text.components(separatedBy: .newlines)
        var provider: String?; var model: String?; var inModel = false
        for line in lines { if line == "model:" { inModel = true; continue }; if inModel && !line.hasPrefix(" ") { break }; if inModel { let t = line.trimmingCharacters(in: .whitespaces); if t.hasPrefix("provider:") { provider = value(t) }; if t.hasPrefix("default:") { model = value(t) } } }
        guard let provider, let model else { return nil }
        var api: String?; var inside = false
        for line in lines { if line == "  \(provider):" { inside = true; continue }; if inside && line.hasPrefix("  ") && !line.hasPrefix("    ") { break }; if inside && line.trimmingCharacters(in: .whitespaces).hasPrefix("api:") { api = value(line.trimmingCharacters(in: .whitespaces)) } }
        guard let api, let url = URL(string: api) else { return nil }
        return (url, model)
    }
    private static func value(_ text: String) -> String { text.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces) }
    private struct Request: Encodable { struct Message: Encodable { let role: String; let content: String }; let model: String; let messages: [Message]; let maxTokens: Int; let temperature: Double; enum CodingKeys: String, CodingKey { case model, messages, temperature; case maxTokens = "max_tokens" } }
    private struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let choices: [Choice] }
}
