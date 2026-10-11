//
//  AIDoseAdviceViews.swift
//  Loop
//
//  The AI dose advice section on the bolus screen, and its settings screen.
//

import SwiftUI
import LoopKit
import LoopKitUI

/// Its own section below the bolus field. Closed until the toggle is turned on; only then is the
/// model asked, and its dose goes into the bolus field only when accepted.
struct AIDoseAdviceSection: View {
    @ObservedObject var viewModel: BolusEntryViewModel
    /// Puts the advice's dose in the bolus field.
    let accept: (AIDoseAdvice) -> Void

    @State private var acceptedDate: Date?

    private var isOpen: Binding<Bool> {
        Binding(
            get: { viewModel.aiDoseAdviceState != .off },
            set: { open in
                acceptedDate = nil
                viewModel.setAIDoseAdviceOpen(open)
            }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: isOpen) {
                Label {
                    Text("AI Dose Advice", comment: "Toggle opening the AI dose advice section on the bolus screen")
                } icon: {
                    Image(systemName: "sparkles")
                }
            }

            switch viewModel.aiDoseAdviceState {
            case .off:
                EmptyView()
            case .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Weighing the meal, glucose and history…", comment: "Shown while the AI dose advice is being worked out")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            case .unavailable(let reason):
                Text(reason)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.red)
                    Button(String(localized: "Try Again", comment: "Button asking for the AI dose advice again")) {
                        viewModel.requestAIDoseAdvice()
                    }
                }
            case .ready(let advice):
                adviceView(advice)
            }
        } footer: {
            if viewModel.aiDoseAdviceState != .off {
                Text("A second opinion from AI. Loop's recommendation above is unchanged; nothing is given unless you accept and deliver it.", comment: "Footer of the AI dose advice section")
            }
        }
    }

    @ViewBuilder
    private func adviceView(_ advice: AIDoseAdvice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Suggests", comment: "Label for the AI suggested dose")
                Spacer()
                Text(viewModel.formatBolusAmount(advice.units))
                    .font(.title)
                    .foregroundColor(.purple)
                Text(QuantityFormatter(for: .internationalUnit()).localizedUnitStringWithPlurality())
                    .foregroundColor(Color(.secondaryLabel))
            }
            .accessibilityElement(children: .combine)

            if let comparison = comparison(advice) {
                Text(comparison)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let limitedFrom = advice.limitedFrom {
                Text(String(format: NSLocalizedString("AI suggested %1$@ U; held to %2$@ U by the limits in settings.", comment: "Note when the AI dose was lowered to a limit (1: AI's dose)(2: dose shown)"), viewModel.formatBolusAmount(limitedFrom), viewModel.formatBolusAmount(advice.units)))
                    .font(.footnote)
                    .foregroundColor(.orange)
            }

            Text(advice.answer.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if !advice.answer.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(advice.answer.reasons, id: \.self) { reason in
                        Text(verbatim: "• \(reason)")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !advice.answer.carbsAssessment.isEmpty {
                Text(verbatim: "🍽 \(advice.answer.carbsAssessment)")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(advice.answer.cautions, id: \.self) { caution in
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(confidenceText(advice.answer.confidence))
                .font(.caption)
                .foregroundColor(.secondary)

            if acceptedDate == advice.date {
                Label(String(localized: "Put in the bolus field", comment: "Shown after the AI dose was accepted"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                HStack(spacing: 12) {
                    Button {
                        viewModel.setAIDoseAdviceOpen(false)
                    } label: {
                        Text("Don't Use", comment: "Button declining the AI dose")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        accept(advice)
                        acceptedDate = advice.date
                    } label: {
                        Text("Use AI Dose", comment: "Button accepting the AI dose into the bolus field")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func comparison(_ advice: AIDoseAdvice) -> String? {
        guard let loop = advice.loopUnits else { return nil }
        let difference = advice.units - loop
        if abs(difference) < 0.025 {
            return String(localized: "Same as Loop", comment: "AI dose equals Loop's recommendation")
        }
        let sign = difference > 0 ? "+" : "−"
        return String(format: NSLocalizedString("%1$@%2$@ U compared with Loop (%3$@ U)", comment: "AI dose compared with Loop's (1: + or −)(2: difference)(3: Loop's recommendation)"), sign, viewModel.formatBolusAmount(abs(difference)), viewModel.formatBolusAmount(loop))
    }

    private func confidenceText(_ confidence: String) -> String {
        switch confidence {
        case "high": return String(localized: "AI confidence: high", comment: "AI dose advice confidence")
        case "low": return String(localized: "AI confidence: low", comment: "AI dose advice confidence")
        default: return String(localized: "AI confidence: medium", comment: "AI dose advice confidence")
        }
    }
}

/// Turns the advice on or off, and holds what the model is told about the child and the limits.
struct AIDoseAdviceSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings = UserDefaults.standard.aiDoseAdviceSettings

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle(isOn: $settings.isEnabled) {
                        Text("AI Dose Advice", comment: "Toggle turning AI dose advice on or off in settings")
                    }
                } footer: {
                    Text("Adds a section below the bolus field where AI can suggest a dose of its own, next to Loop's. It stays closed until opened, so the bolus screen looks as usual. The suggestion considers the meal, glucose now and today, insulin and carbs on board, what you write about the child below, and Nightscout history.", comment: "Explanation of AI dose advice in settings")
                }

                if settings.isEnabled {
                    Section {
                        TextEditor(text: $settings.childProfile)
                            .frame(minHeight: 140)
                    } header: {
                        Text("About the Child", comment: "Header for the child description used by AI dose advice")
                    } footer: {
                        Text("Age, weight, activity (for example more active at kindergarten), habits, and what usually goes wrong. Sent to OpenAI with each request.", comment: "Footer for the child description used by AI dose advice")
                    }

                    Section {
                        Stepper(value: $settings.maximumAboveLoop, in: AIDoseAdviceSettings.maximumAboveLoopRange, step: 0.1) {
                            HStack {
                                Text("Most Above Loop", comment: "Setting: the most the AI dose may be above Loop's recommendation")
                                Spacer()
                                Text(String(format: "%.1f U", settings.maximumAboveLoop))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Stepper(value: $settings.historyDays, in: AIDoseAdviceSettings.historyDaysRange, step: 7) {
                            HStack {
                                Text("Nightscout History", comment: "Setting: how many days of Nightscout history AI dose advice looks at")
                                Spacer()
                                Text(String(format: NSLocalizedString("%d days", comment: "Number of days of history"), settings.historyDays))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Limits", comment: "Header for AI dose advice limits")
                    } footer: {
                        Text("The AI dose is never above the maximum bolus or more than this above Loop's recommendation. No dose is suggested when glucose is low, a low is predicted, or data is stale.", comment: "Footer for AI dose advice limits")
                    }
                }
            }
            .navigationTitle(Text("AI Dose Advice", comment: "Title of the AI dose advice settings screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Button closing the AI dose advice settings")) {
                        dismiss()
                    }
                }
            }
            .onChange(of: settings) { newValue in
                UserDefaults.standard.aiDoseAdviceSettings = newValue
            }
        }
    }
}
