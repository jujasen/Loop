//
//  AddEditFavoriteFoodViewModel.swift
//  Loop
//
//  Created by Noah Brauner on 7/31/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import HealthKit

/// One editable amount while a favorite food is being written. Carries the portion's id so that a
/// carb entry pointing at this amount keeps pointing at it after an edit.
struct FavoriteFoodPortionDraft: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var carbsQuantity: Double? = nil

    init(id: String = UUID().uuidString, name: String = "", carbsQuantity: Double? = nil) {
        self.id = id
        self.name = name
        self.carbsQuantity = carbsQuantity
    }

    init(portion: FavoriteFoodPortion, unit: HKUnit) {
        self.init(id: portion.id, name: portion.name, carbsQuantity: portion.carbsQuantity.doubleValue(for: unit))
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class AddEditFavoriteFoodViewModel: ObservableObject {
    enum Alert: Identifiable {
        var id: Self {
            return self
        }
        
        case maxQuantityExceded
        case warningQuantityValidation
    }
    
    @Published var name = ""

    /// Every amount this food can be logged at. Always holds at least one row.
    @Published var portions: [FavoriteFoodPortionDraft]

    var preferredCarbUnit = HKUnit.gram()
    var maxCarbEntryQuantity = LoopConstants.maxCarbEntryQuantity
    var warningCarbEntryQuantity = LoopConstants.warningCarbEntryQuantity
    
    @Published var foodType = ""

    /// Folder the food is filed under, `nil` for unfiled.
    @Published var folderID: String? = nil

    /// Folders offered in the folder picker. Empty when the caller has no folders to offer.
    let folders: [FavoriteFoodFolder]

    @Published var absorptionTime: TimeInterval
    let minAbsorptionTime = LoopConstants.minCarbAbsorptionTime
    let maxAbsorptionTime = LoopConstants.maxCarbAbsorptionTime
    var absorptionRimesRange: ClosedRange<TimeInterval> {
        return minAbsorptionTime...maxAbsorptionTime
    }
    
    @Published var alert: AddEditFavoriteFoodViewModel.Alert?
    
    private let onSave: (NewFavoriteFood) -> ()
    
    init(originalFavoriteFood: StoredFavoriteFood?, folders: [FavoriteFoodFolder] = [], initialFolderID: String? = nil, onSave: @escaping (NewFavoriteFood) -> ()) {
        self.onSave = onSave
        self.folders = folders
        if let food = originalFavoriteFood {
            self.originalFavoriteFood = food
            self.name = food.name
            self.foodType = food.foodType
            self.absorptionTime = food.absorptionTime
            self.folderID = food.folderID
            self.portions = food.portions.map { FavoriteFoodPortionDraft(portion: $0, unit: HKUnit.gram()) }
        }
        else {
            self.absorptionTime = .hours(3)
            self.folderID = initialFolderID
            self.portions = [FavoriteFoodPortionDraft()]
        }
    }
    
    init(carbsQuantity: Double?, foodType: String, absorptionTime: TimeInterval, folders: [FavoriteFoodFolder] = [], onSave: @escaping (NewFavoriteFood) -> ()) {
        self.onSave = onSave
        self.folders = folders
        self.foodType = foodType
        self.absorptionTime = absorptionTime
        self.portions = [FavoriteFoodPortionDraft(carbsQuantity: carbsQuantity)]
    }

    var folderName: String? {
        guard let folderID, let folder = folders.first(where: { $0.id == folderID }) else { return nil }
        return folder.title
    }

    // MARK: - Serving sizes

    var hasMultiplePortions: Bool {
        portions.count > 1
    }

    func addPortion() {
        withAnimation {
            portions.append(FavoriteFoodPortionDraft())
        }
    }

    func removePortion(id: String) {
        guard portions.count > 1 else { return }
        withAnimation {
            portions.removeAll(where: { $0.id == id })
        }
    }

    /// Placeholder that nudges toward naming amounts once there is more than one.
    var portionNamePlaceholder: String {
        hasMultiplePortions
            ? String(localized: "Whole slice", comment: "Placeholder for the name of one serving size of a favorite food")
            : String(localized: "1 slice", comment: "Placeholder for the free-text serving size row on add favorite food screen")
    }

    /// A food with several amounts needs each of them named, otherwise they cannot be told apart.
    var portionsNeedNames: Bool {
        hasMultiplePortions && portions.contains(where: { $0.trimmedName.isEmpty })
    }

    private var builtPortions: [FavoriteFoodPortion]? {
        guard !portions.isEmpty, !portionsNeedNames else { return nil }
        var built: [FavoriteFoodPortion] = []
        for draft in portions {
            guard let quantity = draft.carbsQuantity, quantity > 0 else { return nil }
            built.append(FavoriteFoodPortion(
                id: draft.id,
                name: draft.trimmedName,
                carbsQuantity: HKQuantity(unit: preferredCarbUnit, doubleValue: quantity)
            ))
        }
        return built
    }

    private var largestPortionQuantity: Double {
        portions.compactMap(\.carbsQuantity).max() ?? 0
    }
    
    var originalFavoriteFood: StoredFavoriteFood?
    var updatedFavoriteFood: NewFavoriteFood? {
        guard !name.isEmpty, !foodType.isEmpty, let builtPortions else { return nil }

        if let o = originalFavoriteFood,
           o.name == name,
           o.foodType == foodType,
           o.absorptionTime == absorptionTime,
           o.folderID == folderID,
           o.portions == builtPortions {
            return nil  // No changes were made
        }

        return NewFavoriteFood(
            name: name,
            portions: builtPortions,
            foodType: foodType,
            absorptionTime: absorptionTime,
            folderID: folderID
        )
    }
    
    func save() {
        guard let updatedFavoriteFood, absorptionTime <= maxAbsorptionTime else { return }

        let largest = largestPortionQuantity
        guard largest > 0 else { return }
        let quantity = HKQuantity(unit: preferredCarbUnit, doubleValue: largest)
        if quantity.compare(maxCarbEntryQuantity) == .orderedDescending {
            self.alert = .maxQuantityExceded
            return
        }
        else if quantity.compare(warningCarbEntryQuantity) == .orderedDescending {
            self.alert = .warningQuantityValidation
            return
        }
        
        onSave(updatedFavoriteFood)
    }
    
    func clearAlertAndSave() {
        guard let updatedFavoriteFood else { return }
        self.alert = nil
        onSave(updatedFavoriteFood)
    }
    
    func clearAlert() {
        self.alert = nil
    }

    /// Quantity shown in the "large meal" warnings.
    var alertQuantity: Double {
        largestPortionQuantity
    }
}
