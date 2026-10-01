//
//  MealEstimateCard.swift
//  Loop
//
//  The "describe the meal" card on the carb entry screen: free text and/or photos of the meal in,
//  carbs, absorption time and an emoji filled into the entry above. The breakdown and the guesses behind the numbers
//  can be opened to check them, and a follow-up re-evaluates the whole meal.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit
import PhotosUI

struct MealEstimateCard: View {
    @Environment(\.carbTintColor) private var carbTintColor

    @ObservedObject var viewModel: CarbEntryViewModel

    @FocusState private var isInputFocused: Bool
    @State private var showsBreakdown = false
    @State private var photoSource: PhotoSource?

    private enum PhotoSource: Int, Identifiable {
        case camera, library
        var id: Int { rawValue }
    }

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

                    photoStrip

                    promptField(
                        String(localized: "Add or correct something…", comment: "Placeholder for adding more information to a meal estimate"),
                        text: $viewModel.mealFollowUp,
                        isEnabled: viewModel.canRefineMealEstimate,
                        accessibilityLabel: String(localized: "Update estimate", comment: "Button label asking AI to re-evaluate the meal with the added information"),
                        action: viewModel.refineMealEstimate
                    )
                }
                else {
                    photoStrip

                    promptField(
                        String(localized: "E.g. fish gratin", comment: "Placeholder for the free-text meal description on the carb entry screen"),
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
            .animation(.easeInOut(duration: 0.2), value: viewModel.mealPhotos)

            if viewModel.mealEstimate != nil {
                Text("AI estimate — check the numbers before you continue.", comment: "Reminder under the meal estimate that the numbers must be reviewed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 26)
            }
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

    // MARK: - Input

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
    private func promptField(_ placeholder: String, text: Binding<String>, isEnabled: Bool, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundColor(carbTintColor)
                .frame(height: 40)

            growingTextField(placeholder, text: text)
                .focused($isInputFocused)
                .padding(.vertical, 9)

            photoButton

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

                totals(for: estimate)
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

    /// "45 g · 3 h", and how many photos the estimate looked at, when it had any.
    private func totals(for estimate: MealCarbEstimate) -> Text {
        let absorption = viewModel.absorptionTimeFormatter.string(from: estimate.absorptionTime(in: viewModel.absorptionRimesRange)) ?? ""
        let text = Text(verbatim: "\(grams(estimate.roundedCarbs)) · \(absorption)")
        let photos = viewModel.mealEstimatePhotoCount
        guard photos > 0 else { return text }
        return text + Text(verbatim: " · ") + Text(Image(systemName: "photo")) + Text(verbatim: " \(photos)")
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
