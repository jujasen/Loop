//
//  FavoriteFoodsViewModel.swift
//  Loop
//
//  Created by Noah Brauner on 7/27/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import HealthKit
import LoopKit
import Combine

/// One group of favorite foods as shown in the list: either a user-created folder, or the
/// trailing group of foods that are not filed anywhere.
struct FavoriteFoodSection: Identifiable {
    static let unfiledID = "com.loopkit.Loop.favoriteFoods.unfiled"

    let folder: FavoriteFoodFolder?
    let foods: [StoredFavoriteFood]

    var id: String { folder?.id ?? Self.unfiledID }
    var isUnfiled: Bool { folder == nil }
}

final class FavoriteFoodsViewModel: ObservableObject {
    @Published var favoriteFoods = UserDefaults.standard.favoriteFoods
    @Published var folders = UserDefaults.standard.favoriteFoodFolders
    @Published var selectedFood: StoredFavoriteFood?
    @Published var searchText = ""

    @Published var isDetailViewActive = false
    @Published var isEditViewActive = false
    @Published var isAddViewActive = false

    /// Folder that a newly added food should be filed into, set when adding from inside a folder.
    @Published var addToFolderID: String?

    /// Non-nil while the folder editor sheet is up. Wraps `nil` folder for "new folder".
    @Published var folderEditorTarget: FolderEditorTarget?

    var preferredCarbUnit = HKUnit.gram()
    lazy var carbFormatter = QuantityFormatter(for: preferredCarbUnit)
    lazy var absorptionTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    
    private lazy var cancellables = Set<AnyCancellable>()
    
    init() {
        observeFavoriteFoodChange()
        observeFolderChange()
    }

    // MARK: - Grouping & search

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Foods grouped by folder, folders first in their stored order and unfiled foods last.
    /// Empty sections are kept so that a folder you just made is visible and can be filled.
    var sections: [FavoriteFoodSection] {
        let foods = filteredFoods
        var sections = folders.map { folder in
            FavoriteFoodSection(folder: folder, foods: foods.filter { resolvedFolderID(for: $0) == folder.id })
        }
        let unfiled = foods.filter { resolvedFolderID(for: $0) == nil }
        if !unfiled.isEmpty || folders.isEmpty {
            sections.append(FavoriteFoodSection(folder: nil, foods: unfiled))
        }
        return sections
    }

    var hasNoMatches: Bool {
        isSearching && filteredFoods.isEmpty
    }

    private var filteredFoods: [StoredFavoriteFood] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return favoriteFoods }
        return favoriteFoods.filter { $0.matches(searchQuery: query) }
    }

    /// A food's folder, ignoring stale references to folders that no longer exist.
    private func resolvedFolderID(for food: StoredFavoriteFood) -> String? {
        guard let folderID = food.folderID, folders.contains(where: { $0.id == folderID }) else {
            return nil
        }
        return folderID
    }

    func folder(withID id: String?) -> FavoriteFoodFolder? {
        guard let id else { return nil }
        return folders.first(where: { $0.id == id })
    }

    // MARK: - Foods

    func onFoodSave(_ newFood: NewFavoriteFood) {
        if isAddViewActive {
            let newStoredFood = StoredFavoriteFood(name: newFood.name, portions: newFood.portions, foodType: newFood.foodType, absorptionTime: newFood.absorptionTime, folderID: newFood.folderID ?? addToFolderID)
            withAnimation {
                favoriteFoods.append(newStoredFood)
            }
            isAddViewActive = false
            addToFolderID = nil
        }
        else if var selectedFood, let selectedFoodIndex = favoriteFoods.firstIndex(of: selectedFood) {
            selectedFood.name = newFood.name
            selectedFood.portions = newFood.portions
            selectedFood.foodType = newFood.foodType
            selectedFood.absorptionTime = newFood.absorptionTime
            selectedFood.folderID = newFood.folderID
            favoriteFoods[selectedFoodIndex] = selectedFood
            self.selectedFood = selectedFood
            isEditViewActive = false
        }
    }
    
    func onFoodDelete(_ food: StoredFavoriteFood) {
        if isDetailViewActive {
            isDetailViewActive = false
        }
        withAnimation {
            _ = favoriteFoods.remove(food)
        }
    }

    /// Reorders within one section, mapping the section-local move back onto the flat store so
    /// that the order shown in the carb entry screen follows along.
    func onFoodReorder(in section: FavoriteFoodSection, from: IndexSet, to: Int) {
        var reordered = section.foods
        reordered.move(fromOffsets: from, toOffset: to)

        let positions = favoriteFoods.indices.filter { resolvedFolderID(for: favoriteFoods[$0]) == section.folder?.id }
        guard positions.count == reordered.count else { return }

        var updated = favoriteFoods
        for (position, food) in zip(positions, reordered) {
            updated[position] = food
        }
        withAnimation {
            favoriteFoods = updated
        }
    }

    func moveFood(_ food: StoredFavoriteFood, toFolderID folderID: String?) {
        guard let index = favoriteFoods.firstIndex(of: food), favoriteFoods[index].folderID != folderID else { return }
        withAnimation {
            favoriteFoods[index].folderID = folderID
        }
        if selectedFood == food {
            selectedFood?.folderID = folderID
        }
    }

    func addFoodTapped(folderID: String? = nil) {
        addToFolderID = folderID
        isAddViewActive = true
    }

    // MARK: - Folders

    enum FolderEditorTarget: Identifiable {
        case new
        case existing(FavoriteFoodFolder)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let folder): return folder.id
            }
        }

        var folder: FavoriteFoodFolder? {
            switch self {
            case .new: return nil
            case .existing(let folder): return folder
            }
        }
    }

    func addFolderTapped() {
        folderEditorTarget = .new
    }

    func renameFolderTapped(_ folder: FavoriteFoodFolder) {
        folderEditorTarget = .existing(folder)
    }

    func onFolderSave(_ folder: FavoriteFoodFolder) {
        withAnimation {
            if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[index] = folder
            }
            else {
                folders.append(folder)
            }
        }
        folderEditorTarget = nil
    }

    /// Deleting a folder never deletes food: everything inside becomes unfiled.
    func onFolderDelete(_ folder: FavoriteFoodFolder) {
        withAnimation {
            for index in favoriteFoods.indices where favoriteFoods[index].folderID == folder.id {
                favoriteFoods[index].folderID = nil
            }
            folders.removeAll(where: { $0.id == folder.id })
        }
        folderEditorTarget = nil
    }

    func onFolderReorder(from: IndexSet, to: Int) {
        withAnimation {
            folders.move(fromOffsets: from, toOffset: to)
        }
    }

    func foodCount(in folder: FavoriteFoodFolder) -> Int {
        favoriteFoods.filter { $0.folderID == folder.id }.count
    }

    // MARK: - Persistence

    private func observeFavoriteFoodChange() {
        $favoriteFoods
            .dropFirst()
            .sink { newValue in
                UserDefaults.standard.favoriteFoods = newValue
            }
            .store(in: &cancellables)
    }

    private func observeFolderChange() {
        $folders
            .dropFirst()
            .removeDuplicates()
            .sink { newValue in
                UserDefaults.standard.favoriteFoodFolders = newValue
            }
            .store(in: &cancellables)
    }
}

extension FavoriteFood {
    /// Matches on the food's name, its serving sizes and emoji, so "skive" finds "Halv skive".
    func matches(searchQuery query: String) -> Bool {
        let haystack = [name, servingSize, foodType] + portions.map(\.name)
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
