//
//  CarbFoodLabel.swift
//  Loop
//
//  Reads and writes the dish's name that a carb entry carries next to its emoji.
//

import Foundation

/// What a carb entry's `foodType` says about the meal: its emoji, and — when the entry came
/// from a favorite food or an AI meal estimate — the dish's name.
///
/// The name rides in `foodType` itself, after the emoji ("🍕 Pizza"), because that field already
/// travels everywhere a carb entry does: HealthKit, Nightscout (`foodType` on the treatment) and
/// the caregiver app's remote carb command. LoopFollow reads it back with the same rules, so
/// change both apps together.
struct CarbFoodLabel: Equatable {
    var emoji: String
    var name: String

    init(emoji: String, name: String) {
        self.emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a stored `foodType`: the leading run of emoji is the emoji, the rest is the name.
    /// A `foodType` with no emoji in front is all name.
    init(foodType: String?) {
        let text = (foodType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = String(text.prefix(while: \.isFoodEmoji))
        self.init(emoji: emoji, name: String(text.dropFirst(emoji.count)))
    }

    /// The `foodType` to store, or nil when there is neither an emoji nor a name.
    var foodType: String? {
        let joined = [emoji, name].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

private extension Character {
    /// True for a character drawn as an emoji. Digits, `#` and `*` carry the emoji property too,
    /// but only turn into emoji with a variation selector or keycap, so they need more than one
    /// scalar to count.
    var isFoodEmoji: Bool {
        guard let first = unicodeScalars.first, first.properties.isEmoji else { return false }
        return first.properties.isEmojiPresentation || unicodeScalars.count > 1
    }
}
