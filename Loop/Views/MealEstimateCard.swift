//
//  MealEstimateCard.swift
//  Loop
//
//  The "describe the meal" card on the carb entry screen: free text in, carbs, absorption time
//  and an emoji filled into the entry above. The breakdown and the guesses behind the numbers
//  can be opened to check them, and a follow-up re-evaluates the whole meal.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit

struct MealEstimateCard: View {
    @Environment(\.carbTintColor) private var carbTintColor

    @ObservedObject var viewModel: CarbEntryViewModel

    @FocusState private var isInputFocused: Bool
    @State private var showsBreakdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DESCRIBE THE MEAL", comment: "Section title for the meal estimate card on the carb entry screen")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 26)

            VStack(alignment: .leading, spacing: 14) {
                if let estimate = viewModel.mealEstimate {
                    summary(for: estimate)

                    if showsBreakdown {
                        breakdown(for: estimate)
                            .transition(.opacity)
                    }

                    promptField(
                        String(localized: "Add or correct something…", comment: "Placeholder for adding more information to a meal estimate"),
                        text: $viewModel.mealFollowUp,
                        isEnabled: viewModel.canRefineMealEstimate,
                        accessibilityLabel: String(localized: "Update estimate", comment: "Button label asking AI to re-evaluate the meal with the added information"),
                        action: viewModel.refineMealEstimate
                    )
                }
                else {
                    promptField(
                        String(localized: "E.g. fish gratin with potatoes", comment: "Placeholder for the free-text meal description on the carb entry screen"),
                        text: $viewModel.mealDescription,
                        isEnabled: viewModel.canEstimateMeal,
                        accessibilityLabel: String(localized: "Estimate carbs", comment: "Button label asking AI to estimate the carbs of the described meal"),
                        action: viewModel.estimateMeal
                    )
                }

                if let error = viewModel.mealEstimateError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.critical)
                }
            }
            .padding(12)
            .background(CardBackground())
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.2), value: showsBreakdown)
            .animation(.easeInOut(duration: 0.2), value: viewModel.mealEstimate)

            if viewModel.mealEstimate != nil {
                Text("AI estimate — check the numbers before you continue.", comment: "Reminder under the meal estimate that the numbers must be reviewed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 26)
            }
        }
    }

    // MARK: - Input

    /// A rounded, chat-style field with its send button inside.
    private func promptField(_ placeholder: String, text: Binding<String>, isEnabled: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundColor(carbTintColor)
                .frame(height: 40)

            growingTextField(placeholder, text: text)
                .focused($isInputFocused)
                .padding(.vertical, 9)

            Button(action: {
                isInputFocused = false
                action()
            }) {
                if viewModel.isEstimatingMeal {
                    ProgressView()
                        .frame(width: 30, height: 30)
                }
                else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(isEnabled ? carbTintColor : Color(.tertiaryLabel))
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(accessibilityLabel)
            .padding(.vertical, 5)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    /// Grows to several lines as the description gets longer, where the OS allows it.
    @ViewBuilder
    private func growingTextField(_ placeholder: String, text: Binding<String>) -> some View {
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...5)
        }
        else {
            TextField(placeholder, text: text)
        }
    }

    // MARK: - Result

    private func summary(for estimate: MealCarbEstimate) -> some View {
        HStack(alignment: .center, spacing: 12) {
            FavoriteFoodEmojiTile(emoji: estimate.foodTypeEmoji, tint: carbTintColor, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(estimate.name)
                    .font(.headline)
                    .lineLimit(2)

                Text(totals(for: estimate))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    confidenceLabel(estimate.confidence)

                    Button(action: { showsBreakdown.toggle() }) {
                        HStack(spacing: 3) {
                            Text(showsBreakdown
                                 ? String(localized: "Hide calculation", comment: "Button hiding the item breakdown of a meal estimate")
                                 : String(localized: "Show calculation", comment: "Button showing the item breakdown of a meal estimate"))
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showsBreakdown ? 180 : 0))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }

            Spacer(minLength: 0)

            Button(action: {
                isInputFocused = false
                showsBreakdown = false
                viewModel.clearMealEstimate()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Start over", comment: "Button label clearing the meal estimate on the carb entry screen"))
        }
    }

    private func breakdown(for estimate: MealCarbEstimate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(estimate.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.food)
                            .font(.subheadline)
                        Text(item.amount)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(grams(item.carbsGrams))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if !estimate.assumptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(estimate.assumptions, id: \.self) { assumption in
                        Text(assumption)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                )
            }
        }
        .padding(.leading, 56)
    }

    private func confidenceLabel(_ confidence: MealCarbEstimate.Confidence) -> some View {
        let (title, color): (String, Color) = {
            switch confidence {
            case .high:
                return (String(localized: "Sure", comment: "Meal estimate confidence: high"), .green)
            case .medium:
                return (String(localized: "Fairly sure", comment: "Meal estimate confidence: medium"), .orange)
            case .low:
                return (String(localized: "Unsure", comment: "Meal estimate confidence: low"), .red)
            }
        }()
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func totals(for estimate: MealCarbEstimate) -> String {
        let absorption = viewModel.absorptionTimeFormatter.string(from: estimate.absorptionTime(in: viewModel.absorptionRimesRange)) ?? ""
        return "\(grams(estimate.roundedCarbs)) · \(absorption)"
    }

    private func grams(_ value: Double) -> String {
        viewModel.carbFormatter.string(from: HKQuantity(unit: viewModel.preferredCarbUnit, doubleValue: value)) ?? "\(value) g"
    }
}
