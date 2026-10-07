import XCTest
@testable import Monopolathy

@MainActor
final class MonopolathyTests: XCTestCase {
    private let fourPlayers: [PlayerEndpoint] = [.hermesLocal, .whiteLotus, .blackLotus, .greenLotus]

    func testGameRequiresFourDistinctPlayerEndpoints() {
        let engine = GameEngine()
        engine.start(endpoints: [.hermesLocal, .whiteLotus, .blackLotus])
        XCTAssertTrue(engine.players.isEmpty)

        engine.start(endpoints: [.hermesLocal, .whiteLotus, .blackLotus, .hermesLocal])
        XCTAssertTrue(engine.players.isEmpty)
    }

    func testGameStartsWithFourPlayersAndOnlyRollIsLegal() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        XCTAssertEqual(engine.players.count, 4)
        XCTAssertEqual(engine.players.map(\.cash), [1_500, 1_500, 1_500, 1_500])
        XCTAssertEqual(engine.legalActions, [.rollDice])
    }

    func testIllegalActionIsRejectedWithoutChangingTurn() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let startingPlayer = engine.currentPlayer?.id
        XCTAssertFalse(engine.submit(.buyProperty))
        XCTAssertEqual(engine.currentPlayer?.id, startingPlayer)
    }

    func testDoublesAwardsAnExtraRoll() {
        let sequence = RollSequence([(1, 1)])
        let engine = GameEngine(dice: { sequence.next() })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .awaitingRoll)
        XCTAssertEqual(engine.currentPlayerIndex, 0)
    }

    func testUnownedPropertyOffersPurchase() {
        let sequence = RollSequence([(3, 3)])
        let engine = GameEngine(dice: { sequence.next() })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .awaitingPurchase)
        XCTAssertEqual(engine.legalActions, [.buyProperty, .declineProperty])
    }

    func testChanceCardMovesPlayerAndPaysGoSalary() {
        let cards = [MonopolyCard(id: "test-go", deck: .chance, effect: .moveTo(0, collectGo: true))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 0)
        XCTAssertEqual(engine.players[0].cash, 1_700)
    }

    func testGetOutOfJailFreeCardLeavesAndReturnsToItsDeck() {
        let cards = [MonopolyCard(id: "test-jail-card", deck: .chance, effect: .getOutOfJailFree)]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let player = engine.players[0]
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].getOutOfJailFreeCards, 1)
        XCTAssertEqual(engine.players[0].getOutOfJailFreeDecks, [.chance])
        XCTAssertEqual(engine.cardCountForTesting(.chance), 0)
        engine.sendToJailForTesting(player.id)
        engine.makeCurrentForTesting(player.id)
        XCTAssertTrue(engine.submit(.useGetOutOfJailFree))
        XCTAssertEqual(engine.players[0].getOutOfJailFreeCards, 0)
        XCTAssertEqual(engine.cardCountForTesting(.chance), 1)
    }

    func testCardDirectedUnownedPropertyOffersPurchase() {
        let cards = [MonopolyCard(id: "test-illinois", deck: .chance, effect: .moveTo(24, collectGo: true))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 24)
        XCTAssertEqual(engine.phase, .awaitingPurchase)
        XCTAssertEqual(engine.legalActions, [.buyProperty, .declineProperty])
    }

    func testNearestRailroadCardChargesDoubleRent() {
        let cards = [MonopolyCard(id: "test-railroad", deck: .chance, effect: .nearestRailroad(doubleRent: true))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        engine.grantPropertiesForTesting([15], to: engine.players[1].id)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 15)
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertEqual(engine.players[1].cash, 1_550)
    }

    func testNearestUtilityCardRollsTenTimesRent() {
        let cards = [MonopolyCard(id: "test-utility", deck: .chance, effect: .nearestUtility)]
        let sequence = RollSequence([(3, 4), (2, 3)])
        let engine = GameEngine(dice: { sequence.next() }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        engine.grantPropertiesForTesting([12], to: engine.players[1].id)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].position, 12)
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertEqual(engine.players[1].cash, 1_550)
    }

    func testDeclinedPropertyUsesValidatedAuction() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        XCTAssertEqual(engine.phase, .auction)
        let bidder = engine.players[1]
        XCTAssertTrue(engine.placeAuctionBid(75, by: bidder.id))
        XCTAssertFalse(engine.placeAuctionBid(75, by: engine.players[2].id))
        XCTAssertTrue(engine.passAuction(by: engine.players[2].id))
        XCTAssertTrue(engine.passAuction(by: engine.players[3].id))
        XCTAssertTrue(engine.passAuction(by: engine.players[0].id))
        XCTAssertTrue(engine.players[1].properties.contains(6))
        XCTAssertEqual(engine.players[1].cash, 1_425)
    }

    func testMortgageAddsHalfPriceAndCannotRepeat() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.buyProperty))
        let owner = engine.players[0]
        XCTAssertTrue(engine.mortgage(spaceID: 6, by: owner.id))
        XCTAssertTrue(engine.mortgagedSpaceIDs.contains(6))
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertFalse(engine.mortgage(spaceID: 6, by: owner.id))
    }

    func testMortgagedPropertyDoesNotCollectRent() {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        let owner = engine.players[1]
        engine.grantPropertiesForTesting([6], to: owner.id)
        XCTAssertTrue(engine.mortgage(spaceID: 6, by: owner.id))
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.players[0].cash, 1_500)
        XCTAssertEqual(engine.players[1].cash, 1_550)
    }

    func testBuildingsRequireACompleteSetAndFollowEvenBuilding() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let owner = engine.players[0]
        XCTAssertFalse(engine.buyBuilding(on: 1, by: owner.id))
        engine.grantPropertiesForTesting([1, 3], to: owner.id)
        XCTAssertTrue(engine.buyBuilding(on: 1, by: owner.id))
        XCTAssertFalse(engine.buyBuilding(on: 1, by: owner.id))
        XCTAssertTrue(engine.buyBuilding(on: 3, by: owner.id))
        XCTAssertEqual(engine.availableHouses, 30)
    }

    func testHotelsUseFiniteInventoryAndPreventMortgagingDevelopedSet() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let owner = engine.players[0]
        engine.grantPropertiesForTesting([1, 3], to: owner.id)
        for _ in 0..<4 {
            XCTAssertTrue(engine.buyBuilding(on: 1, by: owner.id))
            XCTAssertTrue(engine.buyBuilding(on: 3, by: owner.id))
        }
        XCTAssertTrue(engine.buyBuilding(on: 1, by: owner.id))
        XCTAssertEqual(engine.buildingsBySpaceID[1], 5)
        XCTAssertEqual(engine.availableHotels, 11)
        XCTAssertFalse(engine.mortgage(spaceID: 3, by: owner.id))
        XCTAssertTrue(engine.sellBuilding(on: 1, by: owner.id))
        XCTAssertEqual(engine.buildingsBySpaceID[1], 4)
        XCTAssertEqual(engine.availableHotels, 12)
    }

    func testTradeTransfersCashAndUndevelopedProperties() {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let first = engine.players[0]
        let second = engine.players[1]
        engine.grantPropertiesForTesting([1], to: first.id)
        engine.grantPropertiesForTesting([3], to: second.id)
        let offer = TradeOffer(fromPlayerID: first.id, toPlayerID: second.id, fromCash: 100, toCash: 25, fromProperties: [1], toProperties: [3])
        XCTAssertTrue(engine.canExecuteTrade(offer))
        XCTAssertTrue(engine.executeTrade(offer))
        XCTAssertTrue(engine.players[0].properties.contains(3))
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[0].cash, 1_425)
        XCTAssertEqual(engine.players[1].cash, 1_575)
    }

    func testInsolventPlayerTransfersAssetsToCreditor() {
        let cards = [MonopolyCard(id: "test-payment", deck: .chance, effect: .payEachPlayer(50))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        let creditor = engine.players[1]
        engine.grantPropertiesForTesting([1], to: debtor.id)
        engine.setCashForTesting(10, for: debtor.id)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.players[0].bankrupt)
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[0].cash, 0)
        XCTAssertEqual(engine.players[1].cash, 1_550)
        XCTAssertEqual(creditor.id, engine.players[1].id)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
    }

    func testCreditorPaysMortgageInterestForInheritedProperty() {
        let cards = [MonopolyCard(id: "test-payment", deck: .chance, effect: .payEachPlayer(50))]
        let engine = GameEngine(dice: { (3, 4) }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)
        let debtor = engine.players[0]
        let creditor = engine.players[1]
        engine.grantPropertiesForTesting([1], to: debtor.id)
        XCTAssertTrue(engine.mortgage(spaceID: 1, by: debtor.id))
        engine.setCashForTesting(10, for: debtor.id)

        XCTAssertTrue(engine.submit(.rollDice))

        XCTAssertTrue(engine.players[0].bankrupt)
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertTrue(engine.mortgagedSpaceIDs.contains(1))
        XCTAssertEqual(engine.players[1].cash, 1_547)
        XCTAssertEqual(creditor.id, engine.players[1].id)
    }

    func testFinalSolventPlayerWinsAndBankruptSeatsAreSkipped() {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let winner = engine.players[0]
        engine.grantPropertiesForTesting([3], to: winner.id)
        for player in engine.players.dropFirst() { engine.bankruptForTesting(player.id) }
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertEqual(engine.phase, .gameOver)
        XCTAssertEqual(engine.currentPlayer?.id, winner.id)
        guard case let .gameOver(winnerID) = engine.pendingAction else { return XCTFail("Expected game-over state") }
        XCTAssertEqual(winnerID, winner.id)
    }

    func testTurnProtocolAcceptsOnlyCurrentLegalJSONAction() throws {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let snapshot = TurnSnapshot(engine: engine)
        XCTAssertEqual(snapshot.legalActions, ["roll_dice"])
        XCTAssertEqual(try TurnProtocol.action(from: "{\"action\":\"roll_dice\"}", allowed: engine.legalActions), .rollDice)
        XCTAssertThrowsError(try TurnProtocol.action(from: "{\"action\":\"buy_property\"}", allowed: engine.legalActions))
        XCTAssertThrowsError(try TurnProtocol.action(from: "I want to roll", allowed: engine.legalActions))
    }

    func testCoordinatorSubmitsOnlyValidatedTransportAction() async throws {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let action = try await TurnCoordinator().playTurn(engine: engine, transport: FixedTransport(reply: "{\"action\":\"roll_dice\"}"))
        XCTAssertEqual(action, .rollDice)
        XCTAssertNotNil(engine.lastRoll)
    }

    func testAuctionCoordinatorValidatesAndAppliesBid() async throws {
        let engine = GameEngine(dice: { (3, 3) })
        engine.start(endpoints: fourPlayers)
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.declineProperty))
        let bidder = engine.players[1]
        let decision = try await AuctionCoordinator().requestAuctionDecision(engine: engine, bidder: bidder, transport: FixedTransport(reply: "{\"action\":\"bid\",\"amount\":75}"))
        XCTAssertEqual(decision, .bid(75))
        XCTAssertEqual(engine.auction?.leadingBidderID, bidder.id)
        XCTAssertThrowsError(try AuctionProtocol.decision(from: "{\"action\":\"bid\",\"amount\":0}", minimumBid: 76, availableCash: bidder.cash))
    }

    func testTradeCoordinatorExecutesOnlyAcceptedValidatedOffer() async throws {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let proposer = engine.players[0]
        let recipient = engine.players[1]
        engine.grantPropertiesForTesting([1], to: proposer.id)
        let proposal = "{\"action\":\"propose_trade\",\"to_player_id\":\"\(recipient.id.uuidString)\",\"give_cash\":0,\"request_cash\":100,\"give_properties\":[1],\"request_properties\":[]}"
        let result = try await TradeCoordinator().negotiate(
            engine: engine,
            proposer: proposer,
            proposerTransport: FixedTransport(reply: proposal),
            recipientTransport: { _ in FixedTransport(reply: "{\"action\":\"accept\"}") }
        )
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(engine.players[1].properties.contains(1))
        XCTAssertEqual(engine.players[0].cash, 1_600)
        XCTAssertEqual(engine.players[1].cash, 1_400)
    }

    func testAssetCoordinatorAppliesOnlyValidatedMortgage() async throws {
        let engine = GameEngine()
        engine.start(endpoints: fourPlayers)
        let player = engine.players[0]
        engine.grantPropertiesForTesting([6], to: player.id)
        let decision = try await AssetCoordinator().requestDecision(engine: engine, player: player, transport: FixedTransport(reply: "{\"action\":\"mortgage\",\"property_id\":6}"))
        XCTAssertEqual(decision, .mortgage(6))
        XCTAssertTrue(engine.mortgagedSpaceIDs.contains(6))
        XCTAssertEqual(engine.players[0].cash, 1_550)
        XCTAssertThrowsError(try AssetProtocol.decision(from: "{\"action\":\"build\"}"))
    }

    func testThreeConsecutiveDoublesSendsPlayerToJail() {
        let sequence = RollSequence([(1, 1), (1, 1), (1, 1)])
        let cards = [MonopolyCard(id: "test-chest", deck: .communityChest, effect: .collect(0))]
        let engine = GameEngine(dice: { sequence.next() }, deckOrder: cards)
        engine.start(endpoints: fourPlayers)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.rollDice))

        XCTAssertEqual(engine.players[0].position, 10)
        XCTAssertEqual(engine.players[0].inJailTurns, 1)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
    }

    func testJailDoublesMovePlayerWithoutExtraRoll() {
        let engine = GameEngine(dice: { (5, 5) })
        engine.start(endpoints: fourPlayers)
        let jailed = engine.players[0]
        engine.sendToJailForTesting(jailed.id)
        XCTAssertTrue(engine.submit(.attemptJailRoll))
        XCTAssertEqual(engine.players[0].inJailTurns, 0)
        XCTAssertEqual(engine.players[0].position, 20)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
    }

    func testThirdFailedJailRollForcesFineAndMovement() {
        let engine = GameEngine(dice: { (1, 2) })
        engine.start(endpoints: fourPlayers)
        let jailed = engine.players[0]
        engine.sendToJailForTesting(jailed.id)
        for _ in 0..<3 {
            engine.makeCurrentForTesting(jailed.id)
            XCTAssertTrue(engine.submit(.attemptJailRoll))
        }
        XCTAssertEqual(engine.players[0].inJailTurns, 0)
        XCTAssertEqual(engine.players[0].cash, 1_450)
        XCTAssertEqual(engine.players[0].position, 13)
        XCTAssertEqual(engine.phase, .awaitingPurchase)
    }

    func testStandardRulesCatalogHasCompleteCardDecks() {
        let chance = MonopolyCard.standardDeck.filter { $0.deck == .chance }
        let chest = MonopolyCard.standardDeck.filter { $0.deck == .communityChest }
        XCTAssertEqual(chance.count, 16)
        XCTAssertEqual(chest.count, 16)
        XCTAssertEqual(Set(MonopolyCard.standardDeck.map(\.id)).count, 32)
        XCTAssertEqual(StandardRules.totalHouses, 32)
        XCTAssertEqual(StandardRules.totalHotels, 12)
    }

    func testStandardPropertyRentSchedulesAndMonopolies() {
        XCTAssertEqual(StandardRules.baseRent(spaceID: 1, buildings: 0, ownsColorSet: false), 2)
        XCTAssertEqual(StandardRules.baseRent(spaceID: 1, buildings: 0, ownsColorSet: true), 4)
        XCTAssertEqual(StandardRules.baseRent(spaceID: 39, buildings: 5, ownsColorSet: true), 2_000)
        XCTAssertEqual(StandardRules.colorSet(for: 1), Set([1, 3]))
        XCTAssertEqual(StandardRules.mortgageValue(for: BoardSpace.standardBoard[39]), 200)
        XCTAssertEqual(StandardRules.unmortgageCost(for: BoardSpace.standardBoard[39]), 221)
    }
}

private final class RollSequence {
    private var rolls: [(Int, Int)]
    init(_ rolls: [(Int, Int)]) { self.rolls = rolls }
    func next() -> (Int, Int) { rolls.removeFirst() }
}

private struct FixedTransport: PlayerTurnTransport {
    let reply: String
    func respond(to prompt: String) async throws -> String { reply }
}
