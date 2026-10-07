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
