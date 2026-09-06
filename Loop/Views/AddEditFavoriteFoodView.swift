//
//  AddEditFavoriteFoodView.swift
//  Loop
//
//  Created by Noah Brauner on 7/31/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct AddEditFavoriteFoodView: View {
    @Environment(\.dismiss) var dismiss
    
    @StateObject private var viewModel: AddEditFavoriteFoodViewModel
    
    @State private var expandedRow: Row?
    @State private var showHowAbsorptionTimeWorks = false
    
    private var isNewEntry = true
        
    /// Initializer for adding a new favorite food or editing a `StoredFavoriteFood`
    init(originalFavoriteFood: StoredFavoriteFood? = nil, folders: [FavoriteFoodFolder] = [], initialFolderID: String? = nil, onSave: @escaping (NewFavoriteFood) -> Void) {
        self._viewModel = StateObject(wrappedValue: AddEditFavoriteFoodViewModel(originalFavoriteFood: originalFavoriteFood, folders: folders, initialFolderID: initialFolderID, onSave: onSave))
        self.isNewEntry = originalFavoriteFood == nil
    }
    
    /// Initializer for presenting the `AddEditFavoriteFoodView` prepopulated from the `CarbEntryView`
    init(carbsQuantity: Double?, foodType: String, absorptionTime: TimeInterval, folders: [FavoriteFoodFolder] = [], onSave: @escaping (NewFavoriteFood) -> Void) {
        self._viewModel = StateObject(wrappedValue: AddEditFavoriteFoodViewModel(carbsQuantity: carbsQuantity, foodType: foodType, absorptionTime: absorptionTime, folders: folders, onSave: onSave))
    }
    
    var body: some View {
        if isNewEntry {
            NavigationView {
                content
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            dismissButton
                        }
                        
                        ToolbarItem(placement: .navigationBarTrailing) {
                            saveButton
                        }
                    }
                    .navigationBarTitle(String(localized: "New Favorite Food", comment: "Title of new favorite food screen"), displayMode: .inline)
                    .onAppear {
                        expandedRow = .name
                    }
            }
        }
        else {
            content
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if viewModel.updatedFavoriteFood != nil {
                            dismissButton
                        }
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        saveButton
                    }
                }
                .navigationBarBackButtonHidden(viewModel.updatedFavoriteFood != nil)
                .navigationBarTitle(viewModel.originalFavoriteFood?.name ?? "", displayMode: .inline)
        }
    }
    
    private var content: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                card
                    .padding(.top, 12)
                
                saveActionButton
            }
        }
        .alert(item: $viewModel.alert, content: alert(for:))
        .sheet(isPresented: $showHowAbsorptionTimeWorks) {
            HowAbsorptionTimeWorksView()
        }
    }
    
    private var card: some View {
        VStack(spacing: 10) {
            let nameFocused: Binding<Bool> = Binding(get: { expandedRow == .name }, set: { expandedRow = $0 ? .name : nil })
            let foodTypeFocused: Binding<Bool> = Binding(get: { expandedRow == .foodType }, set: { expandedRow = $0 ? .foodType : nil })
            let absorptionTimeFocused: Binding<Bool> = Binding(get: { expandedRow == .absorptionTime }, set: { expandedRow = $0 ? .absorptionTime : nil })
            
            TextFieldRow(text: $viewModel.name, isFocused: nameFocused, title: String(localized: "Name", comment: "Label for name row on add favorite food screen"), placeholder: String(localized: "Apple", comment: "Default name on add favorite food screen"))
            
            CardSectionDivider()

            portionsSection

            CardSectionDivider()
            
            EmojiRow(text: $viewModel.foodType, isFocused: foodTypeFocused, emojiType: .food, title: String(localized: "Food Type", comment: "Label for food type entry on add favorite food screen"))
            
            CardSectionDivider()

            AbsorptionTimePickerRow(absorptionTime: $viewModel.absorptionTime, isFocused: absorptionTimeFocused, validDurationRange: viewModel.absorptionRimesRange, showHowAbsorptionTimeWorks: $showHowAbsorptionTimeWorks)
                .padding(.bottom, 2)

            if !viewModel.folders.isEmpty {
                CardSectionDivider()

                folderRow
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .background(CardBackground())
        .padding(.horizontal)
    }

    // MARK: - Serving sizes

    private var portionsSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Serving Size", comment: "Label for the free-text serving size row on add favorite food screen")
                    .foregroundColor(.primary)

                Spacer()

                Text("Carbs", comment: "Column heading above the carb quantity of each serving size")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach($viewModel.portions) { $portion in
                let nameFocused: Binding<Bool> = Binding(
                    get: { expandedRow == .portionName(portion.id) },
                    set: { expandedRow = $0 ? .portionName(portion.id) : nil }
                )
                let carbsFocused: Binding<Bool> = Binding(
                    get: { expandedRow == .portionCarbs(portion.id) },
                    set: { expandedRow = $0 ? .portionCarbs(portion.id) : nil }
                )

                FavoriteFoodPortionRow(
                    name: $portion.name,
                    quantity: $portion.carbsQuantity,
                    isNameFocused: nameFocused,
                    isQuantityFocused: carbsFocused,
                    namePlaceholder: viewModel.portionNamePlaceholder,
                    preferredCarbUnit: viewModel.preferredCarbUnit,
                    onDelete: viewModel.hasMultiplePortions ? { removePortion(id: portion.id) } : nil
                )
            }

            Button(action: addPortion) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.footnote)

                    Text("Add a serving size", comment: "Button label to add another serving size to a favorite food")
                        .font(.subheadline)

                    Spacer()
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            if viewModel.hasMultiplePortions {
                Text("Give each amount a name so you can tell them apart when logging carbs.", comment: "Hint shown when a favorite food has more than one serving size")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func addPortion() {
        viewModel.addPortion()
        if let newPortion = viewModel.portions.last {
            expandedRow = .portionName(newPortion.id)
        }
    }

    private func removePortion(id: String) {
        if expandedRow == .portionName(id) || expandedRow == .portionCarbs(id) {
            expandedRow = nil
        }
        viewModel.removePortion(id: id)
    }

    private var folderRow: some View {
        HStack {
            Text("Folder", comment: "Label for the folder row on add favorite food screen")
                .foregroundColor(.primary)

            Spacer()

            Menu {
                Button(action: { viewModel.folderID = nil }) {
                    if viewModel.folderID == nil {
                        Label(noFolderTitle, systemImage: "checkmark")
                    }
                    else {
                        Text(noFolderTitle)
                    }
                }

                ForEach(viewModel.folders) { folder in
                    Button(action: { viewModel.folderID = folder.id }) {
                        if viewModel.folderID == folder.id {
                            Label(folder.title, systemImage: "checkmark")
                        }
                        else {
                            Text(folder.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(viewModel.folderName ?? noFolderTitle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundColor(.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var noFolderTitle: String {
        String(localized: "No Folder", comment: "Folder picker option for a favorite food that is not in a folder")
    }

    private func alert(for alert: AddEditFavoriteFoodViewModel.Alert) -> SwiftUI.Alert {
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
                NumberFormatter.localizedString(from: NSNumber(value: viewModel.alertQuantity), number: .none)
            )
            return SwiftUI.Alert(
                title: Text("Large Meal Entered", comment: "Title of the warning shown when a large meal was entered"),
                message: Text(message),
                primaryButton: .default(Text("No, edit amount", comment: "The title of the action used when rejecting the the amount of carbohydrates entered."), action: viewModel.clearAlert),
                secondaryButton: .cancel(Text("Yes", comment: "The title of the action used when confirming entered amount of carbohydrates."), action: viewModel.clearAlertAndSave)
            )
        }
    }
}

extension AddEditFavoriteFoodView {
    private var dismissButton: some View {
        Button(action: dismiss.callAsFunction) {
            Text("Cancel")
        }
    }
    
    private var saveActionButton: some View {
        Button(action: viewModel.save) {
            Text("Save")
        }
        .buttonStyle(ActionButtonStyle())
        .padding()
        .disabled(viewModel.updatedFavoriteFood == nil)
    }
    
    private var saveButton: some View {
        Button(action: viewModel.save) {
            Text("Save")
        }
        .disabled(viewModel.updatedFavoriteFood == nil)
    }
}

extension AddEditFavoriteFoodView {
    enum Row: Equatable {
        case name, foodType, absorptionTime
        case portionName(String)
        case portionCarbs(String)
    }
}
