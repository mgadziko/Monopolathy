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
