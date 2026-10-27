//
//  MealWatchViews.swift
//  Loop
//
//  The meal watch's switch on the carb entry screen and its card on the home screen.
//

import LoopKitUI
import SwiftUI

/// The switch on the carb entry screen.
struct MealWatchSection: View {
    @ObservedObject var viewModel: CarbEntryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { viewModel.isMealWatchOn }, set: viewModel.setMealWatch)) {
                Label {
                    Text("Watch the meal", comment: "Switch on the carb entry screen turning on the AI meal watch")
                } icon: {
                    Image(systemName: "sparkles").foregroundColor(.purple)
                }
            }
            if viewModel.isMealWatchOn {
                Text("The AI looks at glucose every 15 minutes and suggests extra insulin when it is needed. It never gives insulin itself.", comment: "Explanation under the meal watch switch on the carb entry screen")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A watched meal on the home screen: what the watch is doing, and an open suggestion with its
/// buttons.
struct MealWatchCard: View {
    let watch: MealWatch
    var onReview: (MealWatchSuggestion) -> Void
    var onDecline: (MealWatchSuggestion) -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let suggestion = watch.openSuggestion {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "sparkles").foregroundColor(.purple)
                    Text(String(format: NSLocalizedString("Suggested: %1$@ U for %2$@", comment: "Meal watch card title with a suggestion (1: units)(2: name of the meal)"), MealWatchManager.units(suggestion.units), watch.mealDescription))
                        .font(.headline)
                }
                Text(suggestion.reason)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        onReview(suggestion)
                    } label: {
                        Text("Review", comment: "Button opening the bolus screen with the meal watch suggestion")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.insulinTintColor)

                    Button(role: .destructive) {
                        onDecline(suggestion)
                    } label: {
                        Text("Decline", comment: "Button declining the meal watch suggestion")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Text(String(format: NSLocalizedString("Lapses at %@ if not used.", comment: "Meal watch card: when the suggestion lapses (1: time)"), suggestion.expiresAt.formatted(date: .omitted, time: .shortened)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    Image(systemName: "sparkles").foregroundColor(.purple)
                    Text(String(format: NSLocalizedString("Watching %1$@ until %2$@", comment: "Meal watch card while watching (1: name of the meal)(2: time)"), watch.mealDescription, watch.until.formatted(date: .omitted, time: .shortened)))
                        .font(.subheadline)
                    Spacer()
                    Button(action: onStop) {
                        Text("Stop", comment: "Button stopping the meal watch")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}
