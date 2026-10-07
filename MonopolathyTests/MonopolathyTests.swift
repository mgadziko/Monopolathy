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

    func testThreeConsecutiveDoublesSendsPlayerToJail() {
        let sequence = RollSequence([(1, 1), (1, 1), (1, 1)])
        let engine = GameEngine(dice: { sequence.next() })
        engine.start(endpoints: fourPlayers)

        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.rollDice))
        XCTAssertTrue(engine.submit(.rollDice))

        XCTAssertEqual(engine.players[0].position, 10)
        XCTAssertEqual(engine.players[0].inJailTurns, 1)
        XCTAssertEqual(engine.currentPlayerIndex, 1)
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
