import SwiftUI

struct ContentView: View {
    @StateObject private var game = GameEngine()
    @State private var slots = [
        PlayerSlot(id: 0, endpoint: nil, token: "Car"),
        PlayerSlot(id: 1, endpoint: nil, token: "Hat"),
        PlayerSlot(id: 2, endpoint: nil, token: "Dog"),
        PlayerSlot(id: 3, endpoint: nil, token: "Ship")
    ]
    @State private var availability = Dictionary(uniqueKeysWithValues: PlayerEndpoint.allCases.map { ($0, PlayerAvailability.checking) })
    @State private var isAskingPlayer = false
    @State private var isAutoPlaying = false
    @State private var playerTurnStatus: String?

    private var activeEndpoints: [PlayerEndpoint] {
        PlayerEndpoint.allCases.filter { availability[$0]?.isAvailable == true }
    }

    private var canStart: Bool {
        let choices = slots.compactMap(\.endpoint)
        return choices.count == 4 && Set(choices).count == 4 && choices.allSatisfy { availability[$0]?.isAvailable == true }
    }

    var body: some View {
        Group {
            if game.players.isEmpty { lobby } else { table }
        }
        .task { await refreshPlayers() }
    }

    private var lobby: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monopolathy").font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("A standard-rules Monopoly table for four LAN decision-makers.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await refreshPlayers() } } label: { Label("Refresh Players", systemImage: "arrow.clockwise") }
            }

            GroupBox("Players") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        Text("Seat").foregroundStyle(.secondary)
                        Text("Connected player").foregroundStyle(.secondary)
                        Text("Token").foregroundStyle(.secondary)
                    }
                    ForEach($slots) { $slot in
                        GridRow {
                            Text("Player \(slot.id + 1)").fontWeight(.medium)
                            Picker("Player \(slot.id + 1)", selection: $slot.endpoint) {
                                Text("Choose active player").tag(PlayerEndpoint?.none)
                                ForEach(activeEndpoints) { endpoint in
                                    Text(endpoint.displayName).tag(PlayerEndpoint?.some(endpoint))
                                }
                            }
                            .labelsHidden().frame(width: 260)
                            Text(slot.token).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Availability") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PlayerEndpoint.allCases) { endpoint in
                        HStack {
                            Image(systemName: availability[endpoint]?.isAvailable == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(availability[endpoint]?.isAvailable == true ? .green : .secondary)
                            Text(endpoint.displayName).frame(width: 190, alignment: .leading)
                            Text(availability[endpoint]?.label ?? "Not checked").foregroundStyle(.secondary)
                        }
                    }
                }.padding(8)
            }

            HStack {
                Text("Only live, configured player services appear in the four menus. The game will validate every proposed move.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    game.start(endpoints: slots.compactMap(\.endpoint))
                    beginAutomaticPlay()
                } label: { Label("Start Game", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).disabled(!canStart)
            }
        }
        .padding(36).frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Monopolathy").font(.largeTitle.bold())
                    Text("Current player: \(game.currentPlayer?.name ?? "—") • \(game.phase.rawValue)").foregroundStyle(.secondary)
                }
                Spacer()
                if let roll = game.lastRoll { Text("Last roll: \(roll.0) + \(roll.1)").monospacedDigit() }
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Players").font(.headline)
                    ForEach(game.players) { player in
                        Text("\(player.token)  \(player.name): $\(player.cash) • space \(player.position)")
                    }
                }.frame(width: 330, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Table log").font(.headline)
                    ScrollView { LazyVStack(alignment: .leading, spacing: 6) { ForEach(game.log) { Text($0.text).font(.callout) } } }
                }.frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
            }
            if let playerTurnStatus {
                Text(playerTurnStatus).foregroundStyle(.secondary)
            }
            HStack {
                ForEach(game.legalActions, id: \.self) { action in
                    Button(actionTitle(action)) { game.submit(action) }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Button {
                    Task { _ = await askCurrentPlayer() }
                } label: {
                    Label(isAskingPlayer ? "Waiting for Player…" : "Ask Current Player", systemImage: "person.crop.circle.badge.play")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAskingPlayer || isAutoPlaying || game.phase == .auction || game.phase == .trading || game.phase == .gameOver)
                Button {
                    if isAutoPlaying { isAutoPlaying = false } else { beginAutomaticPlay() }
                } label: {
                    Label(isAutoPlaying ? "Stop Automatic Play" : "Resume Automatic Play", systemImage: isAutoPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(isAskingPlayer || game.phase == .auction || game.phase == .trading || game.phase == .gameOver)
                Button("New Game") {
                    isAutoPlaying = false
                    game.returnToLobby()
                }
            }
        }.padding(28)
    }

    private func actionTitle(_ action: GameAction) -> String {
        switch action {
        case .rollDice: "Roll Dice"; case .buyProperty: "Buy"; case .declineProperty: "Decline"; case .payJailFine: "Pay $50"; case .useGetOutOfJailFree: "Use Card"; case .attemptJailRoll: "Roll for Doubles"; case .endTurn: "End Turn"
        }
    }

    @MainActor private func refreshPlayers() async {
        for endpoint in PlayerEndpoint.allCases { availability[endpoint] = .checking }
        await withTaskGroup(of: (PlayerEndpoint, PlayerAvailability).self) { group in
            for endpoint in PlayerEndpoint.allCases { group.addTask { (endpoint, await EndpointProbe.check(endpoint)) } }
            for await (endpoint, result) in group { availability[endpoint] = result }
        }
    }

    @MainActor private func askCurrentPlayer() async -> Bool {
        guard let player = game.currentPlayer else { return false }
        guard player.endpoint.hermesProfileName != nil else {
            playerTurnStatus = "ChatGPT connection is not configured yet."
            return false
        }
        isAskingPlayer = true
        playerTurnStatus = "Waiting for \(player.name)'s legal move…"
        defer { isAskingPlayer = false }
        do {
            let action = try await TurnCoordinator().playTurn(engine: game, transport: HermesTurnTransport(endpoint: player.endpoint))
            playerTurnStatus = "\(player.name) chose \(actionTitle(action))."
            return true
        } catch {
            playerTurnStatus = error.localizedDescription
            return false
        }
    }

    @MainActor private func beginAutomaticPlay() {
        guard !isAutoPlaying, game.phase != .auction, game.phase != .trading, game.phase != .gameOver else { return }
        isAutoPlaying = true
        Task { await playAutomatically() }
    }

    /// Every model still receives only one validated decision at a time. There
    /// is intentionally no delay: a player may immediately take a further
    /// roll after doubles, as standard Monopoly permits.
    @MainActor private func playAutomatically() async {
        defer { isAutoPlaying = false }
        var decisions = 0
        while isAutoPlaying, !Task.isCancelled, decisions < 10_000 {
            guard game.phase != .auction, game.phase != .trading, game.phase != .gameOver else { break }
            guard await askCurrentPlayer() else { break }
            decisions += 1
        }
        if game.phase == .auction {
            playerTurnStatus = "Automatic play paused for an auction; bidding protocol is next."
        } else if game.phase == .trading {
            playerTurnStatus = "Automatic play paused for a trade."
        } else if decisions == 10_000 {
            playerTurnStatus = "Automatic play stopped after 10,000 decisions."
        }
    }
}

enum EndpointProbe {
    static func check(_ endpoint: PlayerEndpoint) async -> PlayerAvailability {
        guard let profile = endpoint.hermesProfileName else { return .unavailable(reason: "ChatGPT connection not configured") }
        let config = URL(fileURLWithPath: NSString(string: "~/.hermes/profiles/\(profile)/config.yaml").expandingTildeInPath)
        guard let text = try? String(contentsOf: config), let backend = selectedBackend(in: text) else { return .unavailable(reason: "Profile not configured") }
        var modelsURL = backend.api
        modelsURL.appendPathComponent("models")
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return .unavailable(reason: "Model service unavailable") }
            let models = try JSONDecoder().decode(ModelList.self, from: data)
            guard models.data.contains(where: { $0.id == backend.model }) else { return .unavailable(reason: "Expected model not loaded") }
            return .available(detail: "Model ready")
        } catch { return .unavailable(reason: "Model service not reachable") }
    }

    private static func selectedBackend(in text: String) -> (api: URL, model: String)? {
        let lines = text.components(separatedBy: .newlines)
        var selectedProvider: String?
        var defaultModel: String?
        var inModel = false
        for line in lines {
            if line == "model:" { inModel = true; continue }
            if inModel && !line.hasPrefix(" ") { break }
            guard inModel else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("provider:") { selectedProvider = value(after: ":", in: trimmed) }
            if trimmed.hasPrefix("default:") { defaultModel = value(after: ":", in: trimmed) }
        }
        guard let selectedProvider, let defaultModel else { return nil }
        let header = "  \(selectedProvider):"
        var inProvider = false
        var api: String?
        for line in lines {
            if line == header { inProvider = true; continue }
            if inProvider && line.hasPrefix("  ") && !line.hasPrefix("    ") { break }
            guard inProvider else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("api:") { api = value(after: ":", in: trimmed) }
        }
        guard let api, let url = URL(string: api) else { return nil }
        return (url, defaultModel)
    }

    private static func value(after separator: Character, in text: String) -> String {
        text.split(separator: separator, maxSplits: 1).dropFirst().joined(separator: String(separator)).trimmingCharacters(in: .whitespaces)
    }

    private struct ModelList: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
}
