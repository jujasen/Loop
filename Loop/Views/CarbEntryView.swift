//
//  CarbEntryView.swift
//  Loop
//
//  Created by Noah Brauner on 7/19/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit

struct CarbEntryView: View, HorizontalSizeClassOverride {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) private var dismiss

    @ObservedObject var viewModel: CarbEntryViewModel
        
    @State private var expandedRow: Row?
    
    @State private var showHowAbsorptionTimeWorks = false
    @State private var showAddFavoriteFood = false
    @State private var showFavoriteFoodPicker = false
    
    private let isNewEntry: Bool

    init(viewModel: CarbEntryViewModel) {
        if viewModel.shouldBeginEditingQuantity {
            expandedRow = .amountConsumed
        }
        isNewEntry = viewModel.originalCarbEntry == nil
        self.viewModel = viewModel
    }
    
    var body: some View {
        if isNewEntry {
            NavigationView {
                let title = NSLocalizedString("carb-entry-title-add", value: "Add Carb Entry", comment: "The title of the view controller to create a new carb entry")
                content
                    .navigationBarTitle(title, displayMode: .inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            dismissButton
                        }
                        
                        ToolbarItem(placement: .navigationBarTrailing) {
                            continueButton
                        }
                    }
                
            }
        }
        else {
            content
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        continueButton
                    }
                }
        }
    }
    
    private var content: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                warningsCard

                mainCard
                    .padding(.top, 8)
                
                continueActionButton
                
                if isNewEntry, FeatureFlags.allowExperimentalFeatures {
                    favoriteFoodsCard
                }
                
                let isBolusViewActive = Binding(get: { viewModel.bolusViewModel != nil }, set: { _, _ in viewModel.bolusViewModel = nil })
                NavigationLink(destination: bolusView, isActive: isBolusViewActive) {
                    EmptyView()
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibility(hidden: true)
            }
        }
        .alert(item: $viewModel.alert, content: alert(for:))
        .sheet(isPresented: $showAddFavoriteFood, onDismiss: clearExpandedRow) {
            AddEditFavoriteFoodView(carbsQuantity: $viewModel.carbsQuantity.wrappedValue, foodType: $viewModel.foodType.wrappedValue, absorptionTime: $viewModel.absorptionTime.wrappedValue, folders: viewModel.favoriteFoodFolders, onSave: onFavoriteFoodSave(_:))
        }
        .sheet(isPresented: $showFavoriteFoodPicker) {
            FavoriteFoodPickerView(
                sections: viewModel.favoriteFoodSections,
                selectedFood: viewModel.selectedFavoriteFood,
                carbFormatter: viewModel.carbFormatter,
                absorptionTimeFormatter: viewModel.absorptionTimeFormatter,
                onSelect: { food in
                    viewModel.selectFavoriteFood(food)
                    showFavoriteFoodPicker = false
                }
            )
        }
        .sheet(isPresented: $showHowAbsorptionTimeWorks) {
            HowAbsorptionTimeWorksView()
        }
    }
    
    private var mainCard: some View {
        VStack(spacing: 10) {
            let amountConsumedFocused: Binding<Bool> = Binding(get: { expandedRow == .amountConsumed }, set: { expandedRow = $0 ? .amountConsumed : nil })
            let timeFocused: Binding<Bool> = Binding(get: { expandedRow == .time }, set: { expandedRow = $0 ? .time : nil })
            let foodTypeFocused: Binding<Bool> = Binding(get: { expandedRow == .foodType }, set: { expandedRow = $0 ? .foodType : nil })
            let absorptionTimeFocused: Binding<Bool> = Binding(get: { expandedRow == .absorptionTime }, set: { expandedRow = $0 ? .absorptionTime : nil })
            
            CarbQuantityRow(quantity: $viewModel.carbsQuantity, isFocused: amountConsumedFocused, title: NSLocalizedString("Amount Consumed", comment: "Label for carb quantity entry row on carb entry screen"), preferredCarbUnit: viewModel.preferredCarbUnit)

            CardSectionDivider()
            
            DatePickerRow(date: $viewModel.time, isFocused: timeFocused, minimumDate: viewModel.minimumDate, maximumDate: viewModel.maximumDate)
            
            CardSectionDivider()
            
            FoodTypeRow(foodType: $viewModel.foodType, absorptionTime: $viewModel.absorptionTime, selectedDefaultAbsorptionTimeEmoji: $viewModel.selectedDefaultAbsorptionTimeEmoji, usesCustomFoodType: $viewModel.usesCustomFoodType, absorptionTimeWasEdited: $viewModel.absorptionTimeWasEdited, isFocused: foodTypeFocused, defaultAbsorptionTimes: viewModel.defaultAbsorptionTimes)
            
            CardSectionDivider()
            
            AbsorptionTimePickerRow(absorptionTime: $viewModel.absorptionTime, isFocused: absorptionTimeFocused, validDurationRange: viewModel.absorptionRimesRange, showHowAbsorptionTimeWorks: $showHowAbsorptionTimeWorks)
                .padding(.bottom, 2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .background(CardBackground())
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var bolusView: some View {
        if let viewModel = viewModel.bolusViewModel {
            BolusEntryView(viewModel: viewModel)
                .environmentObject(displayGlucosePreference)
                .environment(\.dismissAction, dismiss)
        }
    }
    
    private func clearExpandedRow() {
        self.expandedRow = nil
    }
}

// MARK: - Warnings & Alerts
extension CarbEntryView {
    private var warningsCard: some View {
        ForEach(Array(viewModel.warnings).sorted(by: { $0.priority < $1.priority })) { warning in
            warningView(for: warning)
                .padding(.vertical, 8)
                .padding(.horizontal)
                .background(CardBackground())
                .padding(.horizontal)
                .padding(.top, 8)
        }
    }
    
    private func warningView(for warning: CarbEntryViewModel.Warning) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(triangleColor(for: warning))
            
            Text(warningText(for: warning))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func triangleColor(for warning: CarbEntryViewModel.Warning) -> Color {
        switch warning {
        case .entryIsMissedMeal:
            return .critical
        case .overrideInProgress:
            return .warning
        }
    }
    
    private func warningText(for warning: CarbEntryViewModel.Warning) -> String {
        switch warning {
        case .entryIsMissedMeal:
            return NSLocalizedString("Loop has detected an missed meal and estimated its size. Edit the carb amount to match the amount of any carbs you may have eaten.", comment: "Warning displayed when user is adding a meal from an missed meal notification")
        case .overrideInProgress:
            return NSLocalizedString("An active override is modifying your carb ratio and insulin sensitivity. If you don't want this to affect your bolus calculation and projected glucose, consider turning off the override.", comment: "Warning to ensure the carb entry is accurate during an override")
        }
    }
    
    private func alert(for alert: CarbEntryViewModel.Alert) -> SwiftUI.Alert {
        switch alert {
        case .maxQuantityExceded:
            let message = String(
                format: NSLocalizedString("The maximum allowed amount is %@ grams.", comment: "Alert body displayed for quantity greater than max (1: maximum quantity in grams)"),
                NumberFormatter.localizedString(from: NSNumber(value: viewModel.maxCarbEntryQuantity.doubleValue(for: viewModel.preferredCarbUnit)), number: .none)
            )
            let okMessage = NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert")
            return SwiftUI.Alert(
                title: Text("Large Meal Entered", comment: "Title of the warning shown when a large meal was entered"),
                message: Text(message),
                dismissButton: .cancel(Text(okMessage), action: viewModel.clearAlert)
            )
        case .warningQuantityValidation:
            let message = String(
                format: NSLocalizedString("Did you intend to enter %1$@ grams as the amount of carbohydrates for this meal?", comment: "Alert body when entered carbohydrates is greater than threshold (1: entered quantity in grams)"),
                NumberFormatter.localizedString(from: NSNumber(value: viewModel.carbsQuantity ?? 0), number: .none)
            )
            return SwiftUI.Alert(
                title: Text("Large Meal Entered", comment: "Title of the warning shown when a large meal was entered"),
                message: Text(message),
                primaryButton: .default(Text("No, edit amount", comment: "The title of the action used when rejecting the the amount of carbohydrates entered."), action: viewModel.clearAlert),
                secondaryButton: .cancel(Text("Yes", comment: "The title of the action used when confirming entered amount of carbohydrates."), action: viewModel.clearAlertAndContinueToBolus)
            )
        }
    }
}

// MARK: - Favorite Foods Card
extension CarbEntryView {
    private var favoriteFoodsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FAVORITE FOODS", comment: "The section title for Carb entry screen where Favorite Foods can be selected")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 26)
            
            VStack(spacing: 12) {
                if !viewModel.favoriteFoods.isEmpty {
                    quickPickRow

                    CardSectionDivider()

                    browseFavoritesButton

                    CardSectionDivider()
                }
                
                Button(action: saveAsFavoriteFood) {
                    Text("Save as favorite food", comment: "Button label for saving current carb entry as a new Favorite Food")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.saveFavoriteFoodButtonDisabled)
            }
            .padding(.vertical, 12)
            .padding(.horizontal)
            .background(CardBackground())
            .padding(.horizontal)
        }
    }

    /// One tap applies a favorite; tapping the applied favorite again clears it.
    private var quickPickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.favoriteFoods) { food in
                    FavoriteFoodQuickPickChip(
                        food: food,
                        isSelected: viewModel.selectedFavoriteFood == food,
                        action: { viewModel.toggleFavoriteFood(food) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var browseFavoritesButton: some View {
        Button(action: { showFavoriteFoodPicker = true }) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.footnote.weight(.semibold))

                Text("Browse all favorites", comment: "Button label opening the searchable list of Favorite Foods from the carb entry screen")

                Spacer()

                if let selectedFavoriteFood = viewModel.selectedFavoriteFood {
                    Text(selectedFavoriteFood.name)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
        }
    }
    
    private func saveAsFavoriteFood() {
        self.showAddFavoriteFood = true
    }
    
    private func onFavoriteFoodSave(_ food: NewFavoriteFood) {
        clearExpandedRow()
        self.showAddFavoriteFood = false
        viewModel.onFavoriteFoodSave(food)
    }
}

/// A compact, one-tap representation of a favorite food used in the carb entry screen.
struct FavoriteFoodQuickPickChip: View {
    @Environment(\.carbTintColor) private var carbTintColor

    let food: StoredFavoriteFood
    let isSelected: Bool
    let action: () -> Void

    private let cornerRadius: CGFloat = 14

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if food.foodType.isEmpty {
                    Image(systemName: "fork.knife")
                        .font(.footnote)
                        .foregroundColor(carbTintColor)
                }
                else {
                    Text(food.foodType)
                        .font(.body)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(food.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)

                    if food.hasServingSize {
                        Text(food.servingSize)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if isSelected {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? carbTintColor.opacity(0.18) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? carbTintColor : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A searchable, folder-grouped list for choosing a favorite food, presented from the carb entry screen.
struct FavoriteFoodPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.carbTintColor) private var carbTintColor

    let sections: [FavoriteFoodSection]
    let selectedFood: StoredFavoriteFood?
    let carbFormatter: QuantityFormatter
    let absorptionTimeFormatter: DateComponentsFormatter
    let onSelect: (StoredFavoriteFood?) -> Void

    @State private var searchText = ""

    private var filteredSections: [FavoriteFoodSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }
        return sections
            .map { FavoriteFoodSection(folder: $0.folder, foods: $0.foods.filter { $0.matches(searchQuery: query) }) }
            .filter { !$0.foods.isEmpty }
    }

    var body: some View {
        NavigationView {
            List {
                if selectedFood != nil {
                    Section {
                        Button(action: { onSelect(nil) }) {
                            HStack {
                                Image(systemName: "xmark.circle")
                                Text("Clear selection", comment: "Button label clearing the selected Favorite Food")
                            }
                        }
                    }
                }

                if filteredSections.isEmpty {
                    Section {
                        Text("No matching foods", comment: "Title shown when a favorite food search returns nothing")
                            .foregroundColor(.secondary)
                    }
                }
                else {
                    ForEach(filteredSections) { section in
                        Section(header: Text(sectionTitle(for: section))) {
                            ForEach(section.foods) { food in
                                Button(action: { onSelect(food) }) {
                                    row(for: food)
                                }
                            }
                        }
                    }
                }
            }
            .insetGroupedListStyle()
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search foods", comment: "Placeholder for the favorite foods search field"))
            .navigationBarTitle(String(localized: "Favorite Foods", comment: "Title for Favorite Foods view"), displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: dismiss.callAsFunction) {
                        Text("Cancel", comment: "Button label for cancel")
                    }
                }
            }
        }
    }

    private func row(for food: StoredFavoriteFood) -> some View {
        HStack(spacing: 12) {
            FavoriteFoodEmojiTile(emoji: food.foodType, tint: carbTintColor, size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(food.name)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)

                if food.hasServingSize {
                    Text(food.servingSize)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text(FavoriteFoodSummary.carbsAndAbsorption(for: food, carbFormatter: carbFormatter, absorptionTimeFormatter: absorptionTimeFormatter))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            if selectedFood == food {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func sectionTitle(for section: FavoriteFoodSection) -> String {
        if let folder = section.folder {
            return folder.title
        }
        else if sections.count > 1 {
            return String(localized: "Not in a Folder", comment: "Section header for favorite foods that are not filed in a folder")
        }
        else {
            return String(localized: "All Favorites", comment: "section header for list of existing FavoriteFoods")
        }
    }
}

// MARK: - Other UI Elements
extension CarbEntryView {
    private var dismissButton: some View {
        Button(action: dismiss) {
            Text("Cancel", comment: "Button label for cancel")
        }
    }
    
    private var continueButton: some View {
        Button(action: viewModel.continueToBolus) {
            Text("Continue", comment: "Button label for continue")
        }
        .disabled(viewModel.continueButtonDisabled)
    }
    
    private var continueActionButton: some View {
        Button(action: viewModel.continueToBolus) {
            Text("Continue", comment: "Button label for continue")
        }
        .buttonStyle(ActionButtonStyle())
        .padding()
        .disabled(viewModel.continueButtonDisabled)
    }
    
}

extension CarbEntryView {
    enum Row {
        case amountConsumed, time, foodType, absorptionTime
    }
}
