import SwiftUI
import Network

struct ContentView: View {
    @StateObject private var game = GameEngine()
    @State private var slots = [
        PlayerSlot(id: 0, endpoint: nil, token: "Car"),
        PlayerSlot(id: 1, endpoint: nil, token: "Hat"),
        PlayerSlot(id: 2, endpoint: nil, token: "Dog"),
        PlayerSlot(id: 3, endpoint: nil, token: "Ship")
    ]
    @State private var availability = Dictionary(uniqueKeysWithValues: PlayerEndpoint.allCases.map { ($0, PlayerAvailability.checking) })

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
                Button { game.start(endpoints: slots.compactMap(\.endpoint)) } label: { Label("Start Game", systemImage: "play.fill") }
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
            HStack {
                ForEach(game.legalActions, id: \.self) { action in
                    Button(actionTitle(action)) { game.submit(action) }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Button("New Game") { game.returnToLobby() }
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
}

enum EndpointProbe {
    static func check(_ endpoint: PlayerEndpoint) async -> PlayerAvailability {
        guard let profile = endpoint.hermesProfileName else { return .unavailable(reason: "ChatGPT connection not configured") }
        let config = URL(fileURLWithPath: NSString(string: "~/.hermes/profiles/\(profile)/config.yaml").expandingTildeInPath)
        guard let text = try? String(contentsOf: config), let api = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("api:") })?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), let url = URL(string: api), let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else { return .unavailable(reason: "Profile not configured") }
        let available = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            var finished = false
            func finish(_ value: Bool) { guard !finished else { return }; finished = true; connection.cancel(); continuation.resume(returning: value) }
            connection.stateUpdateHandler = { state in if case .ready = state { finish(true) }; if case .failed = state { finish(false) } }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(false) }
        }
        return available ? .available(detail: "Ready") : .unavailable(reason: "Not reachable")
    }
}
