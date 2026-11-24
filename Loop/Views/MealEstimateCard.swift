//
//  MealEstimateCard.swift
//  Loop
//
//  The "ask about carbs" card on the carb entry screen: a question, a description and/or photos
//  of the meal in, carbs, absorption time and an emoji filled into the entry below. The breakdown
//  and the guesses behind the numbers can be opened to check them, and a follow-up (typed, or one
//  of the quick ones) re-evaluates the whole meal.
//
//  It is worded as a place to ask, the way one would ask a chatbot, because the caregivers at
//  kindergarten asked a chatbot app instead: «describe the meal» read as logging, not asking.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit
import PhotosUI

struct MealEstimateCard: View {
    @Environment(\.carbTintColor) private var carbTintColor

    @ObservedObject var viewModel: CarbEntryViewModel
    /// Opens the favorite food editor with the answer filled in; nil where favorites can't be saved.
    var onSaveFavorite: (() -> Void)? = nil

    @FocusState private var isInputFocused: Bool
    @State private var showsBreakdown = false
    @State private var photoSource: PhotoSource?

    private enum PhotoSource: Int, Identifiable {
        case camera, library
        var id: Int { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("ASK ABOUT CARBS", comment: "Section title for the meal estimate card on the carb entry screen")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(accentGradient)
            .padding(.horizontal, 26)

            VStack(alignment: .leading, spacing: 14) {
                if let estimate = viewModel.mealEstimate {
                    summary(for: estimate)

                    if showsBreakdown {
                        breakdown(for: estimate)
                            .transition(.opacity)
                    }

                    if !viewModel.isEstimatingMeal {
                        if let onSaveFavorite {
                            saveFavoriteButton(action: onSaveFavorite)
                        }

                        quickFollowUps
                    }

                    photoStrip

                    promptField(
                        String(localized: "Ask more or correct something…", comment: "Placeholder for adding more information to a meal estimate"),
                        text: $viewModel.mealFollowUp,
                        isEnabled: viewModel.canRefineMealEstimate,
                        accessibilityLabel: String(localized: "Update estimate", comment: "Button label asking AI to re-evaluate the meal with the added information"),
                        action: viewModel.refineMealEstimate
                    )
                }
                else {
                    photoStrip

                    promptField(
                        String(localized: "Type the food", comment: "Accessibility label of the empty meal estimate field, whose placeholder cycles through examples"),
                        examples: Self.examples,
                        text: $viewModel.mealDescription,
                        isEnabled: viewModel.canEstimateMeal,
                        accessibilityLabel: String(localized: "Estimate carbs", comment: "Button label asking AI to estimate the carbs of the described meal"),
                        action: viewModel.estimateMeal
                    )
                }

                if viewModel.isEstimatingMeal, let startedAt = viewModel.mealEstimateStartedAt {
                    waitingLine(since: startedAt)
                }

                if let error = viewModel.mealEstimateError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.critical)
                }
            }
            .padding(12)
            .background(cardBackground)
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.2), value: showsBreakdown)
            .animation(.easeInOut(duration: 0.2), value: viewModel.mealEstimate)
            .animation(.easeInOut(duration: 0.2), value: viewModel.mealPhotos)

            Group {
                if viewModel.mealEstimate != nil {
                    Text("AI estimate — check the numbers before you continue.", comment: "Reminder under the meal estimate that the numbers must be reviewed")
                } else {
                    Text("Just type the food, ask a question or take a photo. The answer fills in the carbs below.", comment: "Explanation under the empty meal estimate card, which is above the carb entry")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 26)
        }
        .fullScreenCover(item: $photoSource) { source in
            switch source {
            case .camera:
                CameraPicker { image in viewModel.addMealPhoto(image) }
                    .ignoresSafeArea()
            case .library:
                PhotoLibraryPicker(limit: MealCarbEstimator.maxPhotosPerMessage - viewModel.mealPhotos.count) { images in
                    images.forEach(viewModel.addMealPhoto)
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Style

    /// The AI's colours: the carb green running into teal and violet, so the card stands out
    /// from the plain cards around it as the place to ask.
    private var gradientColors: [Color] {
        [carbTintColor, .teal, .indigo]
    }

    private var accentGradient: LinearGradient {
        LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing)
    }

    /// A faint wash of the same colours, under a thin border in them.
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            shape.fill(Color(.secondarySystemGroupedBackground))
            shape.fill(
                LinearGradient(
                    colors: gradientColors.map { $0.opacity(0.16) },
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: gradientColors.map { $0.opacity(0.7) },
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.5
            )
        }
        .shadow(color: Color.indigo.opacity(0.14), radius: 12, x: 0, y: 4)
    }

    // MARK: - Input

    /// One tap for the corrections asked most often; "weighed it" puts the start of the sentence
    /// in the field, for the weight to be typed after it.
    private var quickFollowUps: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickFollowUpButton(String(localized: "Only half", comment: "Quick follow-up on a meal estimate: the child ate half of it")) {
                    isInputFocused = false
                    viewModel.refineMealEstimate(.half)
                }
                quickFollowUpButton(String(localized: "Twice as much", comment: "Quick follow-up on a meal estimate: the child ate twice as much")) {
                    isInputFocused = false
                    viewModel.refineMealEstimate(.double)
                }
                quickFollowUpButton(String(localized: "I weighed it", comment: "Quick follow-up on a meal estimate: starts a sentence giving the weight of the food")) {
                    viewModel.mealFollowUp = String(localized: "It weighed ", comment: "Start of the follow-up sentence giving the weight of the food, followed by the weight the caregiver types")
                    isInputFocused = true
                }
            }
        }
    }

    /// Saving the answer turns the next time into one tap on a favorite.
    private func saveFavoriteButton(action: @escaping () -> Void) -> some View {
        let isSaved = viewModel.selectedFavoriteFood != nil
        return Button(action: {
            isInputFocused = false
            action()
        }) {
            Label(
                isSaved
                    ? String(localized: "Saved as favorite food", comment: "Shown on a meal estimate once it has been saved as a favorite food")
                    : String(localized: "Save as favorite – one tap next time", comment: "Button saving a meal estimate as a favorite food"),
                systemImage: isSaved ? "star.fill" : "star"
            )
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .disabled(isSaved || viewModel.saveFavoriteFoodButtonDisabled)
    }

    /// What is happening while the answer is on its way: a search or photos can take a minute,
    /// and a spinner alone looks stuck long before that.
    private func waitingLine(since startedAt: Date) -> some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(waitingTitle(after: seconds))
                        .font(.subheadline)
                    if seconds >= 10 {
                        Text("It can take up to a minute. Keep the screen open.", comment: "Shown under a meal estimate that is taking a while")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Text(verbatim: "\(seconds) s")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private func waitingTitle(after seconds: Int) -> String {
        if seconds < 10 {
            return String(localized: "Working out the carbs…", comment: "First line while a meal estimate is on its way")
        }
        if !viewModel.mealPhotos.isEmpty || viewModel.mealEstimatePhotoCount > 0 {
            return String(localized: "Looking at the photos…", comment: "Line while a meal estimate with photos takes a while")
        }
        return String(localized: "Looking the food up…", comment: "Line while a meal estimate takes a while, usually because it searches the web")
    }

    private func quickFollowUpButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(carbTintColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(carbTintColor.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    /// The photos that go with the next message, each with a button to take it out again.
    @ViewBuilder
    private var photoStrip: some View {
        if !viewModel.mealPhotos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.mealPhotos.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button(action: { viewModel.removeMealPhoto(at: index) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.black.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(viewModel.isEstimatingMeal)
                                    .padding(3)
                                    .accessibilityLabel(Text("Remove photo", comment: "Button label removing a photo from the meal estimate"))
                                }
                        }
                    }
                }
            }
        }
    }

    /// Takes a photo or picks some from the library, up to what one message may carry.
    private var photoButton: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(action: { photoSource = .camera }) {
                    Label(String(localized: "Take Photo", comment: "Menu item taking a photo of the meal for the meal estimate"), systemImage: "camera")
                }
            }
            Button(action: { photoSource = .library }) {
                Label(String(localized: "Choose Photos", comment: "Menu item choosing photos of the meal for the meal estimate"), systemImage: "photo.on.rectangle")
            }
        } label: {
            Image(systemName: "camera")
                .font(.system(size: 19))
                .foregroundColor(viewModel.canAddMealPhoto ? .secondary : Color(.tertiaryLabel))
                .frame(width: 30, height: 30)
        }
        .disabled(!viewModel.canAddMealPhoto)
        .accessibilityLabel(Text("Add photo of the meal", comment: "Button label adding a photo to the meal estimate"))
        .padding(.vertical, 5)
    }

    /// A rounded, chat-style field with its send button inside.
    /// What the empty field shows in turn: mostly just the food, as it is enough, and one
    /// question, to show that asking works too.
    static let examples = [
        String(localized: "1 Nonstop and 1 jelly man", comment: "Example in the empty meal estimate field: just the foods, no question"),
        String(localized: "2 wholemeal rolls", comment: "Example in the empty meal estimate field: just the foods, no question"),
        String(localized: "a glass of milk and a banana", comment: "Example in the empty meal estimate field: just the foods, no question"),
        String(localized: "carbs in a fruit pouch?", comment: "Example in the empty meal estimate field: a question"),
    ]

    private static let exampleInterval: TimeInterval = 3

    /// The placeholder, one example at a time, sliding up to the next every few seconds.
    private func cyclingExamples(_ examples: [String]) -> some View {
        TimelineView(.periodic(from: .now, by: Self.exampleInterval)) { context in
            let index = Int(context.date.timeIntervalSinceReferenceDate / Self.exampleInterval) % examples.count
            ZStack(alignment: .leading) {
                Text(String(format: String(localized: "E.g. %@", comment: "An example shown in the empty meal estimate field (1: the example)"), examples[index]))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .animation(.easeInOut(duration: 0.35), value: index)
        }
        .foregroundColor(Color(.placeholderText))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func promptField(_ placeholder: String, examples: [String]? = nil, text: Binding<String>, isEnabled: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentGradient)
                .frame(height: 40)

            growingTextField(examples == nil ? placeholder : "", text: text)
                .accessibilityLabel(placeholder)
                .overlay(alignment: .leading) {
                    if let examples, text.wrappedValue.isEmpty {
                        cyclingExamples(examples)
                    }
                }
                .focused($isInputFocused)
                .padding(.vertical, 9)

            photoButton

            Button(action: {
                if viewModel.isEstimatingMeal {
                    // Stops the estimate so the text can be corrected; the field gets the keyboard back.
                    viewModel.cancelMealEstimate()
                    isInputFocused = true
                } else {
                    isInputFocused = false
                    action()
                }
            }) {
                if viewModel.isEstimatingMeal {
                    ZStack {
                        ProgressView()
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9))
                            .foregroundColor(carbTintColor)
                    }
                    .frame(width: 30, height: 30)
                }
                else {
                    ZStack {
                        Circle()
                            .fill(isEnabled ? AnyShapeStyle(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color(.tertiaryLabel)))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled && !viewModel.isEstimatingMeal)
            .accessibilityLabel(viewModel.isEstimatingMeal ? String(localized: "Stop estimate", comment: "Button label stopping the AI meal estimate so the description can be corrected") : accessibilityLabel)
            .padding(.vertical, 5)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(isInputFocused ? AnyShapeStyle(accentGradient) : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: isInputFocused ? 1.5 : 1)
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

                totals(for: estimate)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)

                if estimate.items.count == 1, let per100g = estimate.items[0].carbsPer100g, per100g > 0 {
                    // For a single food, the number to multiply the weight by, as a chatbot would give.
                    Text(String(format: String(localized: "%@ per 100 g", comment: "Carbs per 100 g of a food in a meal estimate (1: carbs in grams)"), grams(per100g)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let reason = estimate.absorptionReason, !reason.isEmpty {
                    // Why this absorption time: often the one thing the caregiver doesn't know.
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                        Text(amountLine(for: item))
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

    /// "45 g · 3 h", and how many photos the estimate looked at, when it had any.
    private func totals(for estimate: MealCarbEstimate) -> Text {
        let absorption = viewModel.absorptionTimeFormatter.string(from: estimate.absorptionTime(in: viewModel.absorptionRimesRange)) ?? ""
        let text = Text(verbatim: "\(grams(estimate.roundedCarbs)) · \(absorption)")
        let photos = viewModel.mealEstimatePhotoCount
        guard photos > 0 else { return text }
        return text + Text(verbatim: " · ") + Text(Image(systemName: "photo")) + Text(verbatim: " \(photos)")
    }

    /// "1 stk, ca. 70 g · 41 g per 100 g", when the model said what the food holds per 100 g.
    private func amountLine(for item: MealCarbEstimate.Item) -> String {
        guard let per100g = item.carbsPer100g, per100g > 0 else { return item.amount }
        let per100gText = String(format: String(localized: "%@ per 100 g", comment: "Carbs per 100 g of a food in a meal estimate (1: carbs in grams)"), grams(per100g))
        return "\(item.amount) · \(per100gText)"
    }

    private func grams(_ value: Double) -> String {
        viewModel.carbFormatter.string(from: HKQuantity(unit: viewModel.preferredCarbUnit, doubleValue: value)) ?? "\(value) g"
    }
}

// MARK: - Photo pickers

/// The camera, for photographing the plate. Calls back once with the photo, and not at all when
/// the caregiver cancels.
private struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// The photo library, for photos taken before the carb screen was opened. Needs no photo library
/// permission: the system picker hands over only what was chosen.
private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let limit: Int
    let onPick: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = max(limit, 1)
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
            guard !providers.isEmpty else { return }

            // Keep the order they were picked in, whatever order they finish loading in.
            var images = [UIImage?](repeating: nil, count: providers.count)
            let group = DispatchGroup()
            for (index, provider) in providers.enumerated() {
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    DispatchQueue.main.async {
                        images[index] = object as? UIImage
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { [parent] in
                parent.onPick(images.compactMap { $0 })
            }
        }
    }
}
