//
//  CarbFoodLabelTests.swift
//  LoopTests
//
//  The dish's name travels inside `foodType` to Nightscout and LoopFollow, which splits it the
//  same way. LoopFollow's `Tests/CarbFoodLabelTests.swift` mirrors these cases — change both.
//

import XCTest
@testable import Loop

final class CarbFoodLabelTests: XCTestCase {
    func testEmojiAndNameJoinWithASpace() {
        XCTAssertEqual(CarbFoodLabel(emoji: "🍕", name: "Pizza").foodType, "🍕 Pizza")
    }

    func testEmptyPartsAreLeftOut() {
        XCTAssertEqual(CarbFoodLabel(emoji: "🍕", name: " ").foodType, "🍕")
        XCTAssertEqual(CarbFoodLabel(emoji: "", name: "Pizza").foodType, "Pizza")
        XCTAssertNil(CarbFoodLabel(emoji: "", name: "").foodType)
    }

    func testSplitsEmojiFromName() {
        XCTAssertEqual(CarbFoodLabel(foodType: "🍕 Pizza"), CarbFoodLabel(emoji: "🍕", name: "Pizza"))
        XCTAssertEqual(CarbFoodLabel(foodType: "🍝 Pasta med kjøttsaus"), CarbFoodLabel(emoji: "🍝", name: "Pasta med kjøttsaus"))
    }

    func testEmojiOnlyHasNoName() {
        XCTAssertEqual(CarbFoodLabel(foodType: "🌮"), CarbFoodLabel(emoji: "🌮", name: ""))
        XCTAssertEqual(CarbFoodLabel(foodType: "🍽️"), CarbFoodLabel(emoji: "🍽️", name: ""))
    }

    func testSeveralEmojiStayTogether() {
        XCTAssertEqual(CarbFoodLabel(foodType: "🍔🍟 Burger og pommes"), CarbFoodLabel(emoji: "🍔🍟", name: "Burger og pommes"))
    }

    func testTextWithoutEmojiIsAllName() {
        XCTAssertEqual(CarbFoodLabel(foodType: "Simulated"), CarbFoodLabel(emoji: "", name: "Simulated"))
        XCTAssertEqual(CarbFoodLabel(foodType: "2 brødskiver"), CarbFoodLabel(emoji: "", name: "2 brødskiver"))
    }

    func testMissingFoodTypeIsEmpty() {
        XCTAssertEqual(CarbFoodLabel(foodType: nil), CarbFoodLabel(emoji: "", name: ""))
    }

    func testRoundTrips() {
        for foodType in ["🍕 Pizza", "🌮", "Pasta", "🍔🍟 Burger og pommes"] {
            XCTAssertEqual(CarbFoodLabel(foodType: foodType).foodType, foodType)
        }
    }

    func testChartPillShowsEmojiAndName() {
        let carbs = NSLocalizedString("Carbs", comment: "Chart label for a carb entry")
        XCTAssertEqual(BGChartModel.carbPillText(food: CarbFoodLabel(foodType: "🍕 Pizza"), grams: 30, time: "12:30"), "\(carbs) 🍕\nPizza\n30g\n12:30")
        XCTAssertEqual(BGChartModel.carbPillText(food: CarbFoodLabel(foodType: "🌮"), grams: 30, time: "12:30"), "\(carbs) 🌮\n30g\n12:30")
        XCTAssertEqual(BGChartModel.carbPillText(food: CarbFoodLabel(foodType: nil), grams: 30, time: "12:30"), "\(carbs)\n30g\n12:30")
    }
}
