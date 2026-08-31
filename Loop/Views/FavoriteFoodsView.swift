//
//  FavoriteFoodsView.swift
//  Loop
//
//  Created by Noah Brauner on 7/12/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI

struct FavoriteFoodsView: View {
    @Environment(\.dismissAction) private var dismiss
    
    @StateObject private var viewModel = FavoriteFoodsViewModel()

    @State private var foodToConfirmDeleteId: String? = nil
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationView {
            VStack {
                List {
                    if viewModel.favoriteFoods.isEmpty && viewModel.folders.isEmpty {
                        Section {
                            emptyState
                        }
                    }
                    else if viewModel.hasNoMatches {
                        Section {
                            noMatchesState
                        }
                    }
                    else {
                        ForEach(viewModel.sections) { section in
                            Section(header: sectionHeader(for: section)) {
                                if section.foods.isEmpty {
                                    emptyFolderRow(for: section)
                                }

                                ForEach(section.foods) { food in
                                    FavoriteFoodListRow(food: food, foodToConfirmDeleteId: $foodToConfirmDeleteId, onFoodTap: onFoodTap(_:), onFoodDelete: viewModel.onFoodDelete(_:), carbFormatter: viewModel.carbFormatter, absorptionTimeFormatter: viewModel.absorptionTimeFormatter, preferredCarbUnit: viewModel.preferredCarbUnit)
                                        .environment(\.editMode, self.$editMode)
                                        .listRowInsets(EdgeInsets())
                                        .contextMenu {
                                            moveMenuItems(for: food)
                                        }
                                }
                                .onMove(perform: { from, to in
                                    viewModel.onFoodReorder(in: section, from: from, to: to)
                                })
                                .moveDisabled(!editMode.isEditing || viewModel.isSearching)
                                .deleteDisabled(true)
                            }
                        }
                    }
                    
                    Section {
                        addFoodButton
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)

                        addFolderButton
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    }
                }
                .insetGroupedListStyle()
                .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text("Search foods", comment: "Placeholder for the favorite foods search field"))
                
                
                NavigationLink(destination: AddEditFavoriteFoodView(originalFavoriteFood: viewModel.selectedFood, folders: viewModel.folders, onSave: viewModel.onFoodSave(_:)), isActive: $viewModel.isEditViewActive) {
                    EmptyView()
                }
                
                NavigationLink(destination: FavoriteFoodDetailView(food: viewModel.selectedFood, folderTitle: viewModel.folder(withID: viewModel.selectedFood?.folderID)?.title, onFoodDelete: viewModel.onFoodDelete(_:), carbFormatter: viewModel.carbFormatter, absorptionTimeFormatter: viewModel.absorptionTimeFormatter, preferredCarbUnit: viewModel.preferredCarbUnit), isActive: $viewModel.isDetailViewActive) {
                    EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !viewModel.favoriteFoods.isEmpty {
                        editButton
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    dismissButton
                }
            }
            .navigationBarTitle(String(localized: "Favorite Foods", comment: "Title for Favorite Foods view"), displayMode: .large)
        }
        .sheet(isPresented: $viewModel.isAddViewActive) {
            AddEditFavoriteFoodView(folders: viewModel.folders, initialFolderID: viewModel.addToFolderID, onSave: viewModel.onFoodSave(_:))
        }
        .sheet(item: $viewModel.folderEditorTarget) { target in
            FavoriteFoodFolderEditorView(folder: target.folder, onSave: viewModel.onFolderSave(_:), onDelete: viewModel.onFolderDelete(_:))
        }
        .onChange(of: editMode) { newValue in
            if !newValue.isEditing {
                foodToConfirmDeleteId = nil
            }
        }
    }
    
    private func onFoodTap(_ food: StoredFavoriteFood) {
        viewModel.selectedFood = food
        if editMode.isEditing {
            viewModel.isEditViewActive = true
        }
        else {
            viewModel.isDetailViewActive = true
        }
    }
}

extension FavoriteFoodsView {
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text("Selecting a favorite food in the carb entry screen automatically fills in the carb quantity, food type, and absorption time fields! Tap the add button below to create your first favorite food!")

            Text("Give each food a name and a serving size — like “1 bowl” — and file it in a folder to keep your list tidy.", comment: "Explanation of serving sizes and folders shown when there are no favorite foods yet")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No matching foods", comment: "Title shown when a favorite food search returns nothing")
                .font(.body.weight(.semibold))

            Text("Try a different name or serving size.", comment: "Hint shown when a favorite food search returns nothing")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(for section: FavoriteFoodSection) -> some View {
        HStack(spacing: 8) {
            Text(sectionTitle(for: section))
                .font(.title3)
                .fontWeight(.semibold)
                .textCase(nil)
                .foregroundColor(.primary)

            if !section.foods.isEmpty {
                Text("\(section.foods.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color(.tertiarySystemFill))
                    )
            }

            Spacer()

            if let folder = section.folder {
                folderMenu(for: folder)
            }
        }
        .listRowInsets(EdgeInsets(top: 20, leading: 4, bottom: 10, trailing: 4))
    }

    private func sectionTitle(for section: FavoriteFoodSection) -> String {
        if let folder = section.folder {
            return folder.title
        }
        else if viewModel.folders.isEmpty {
            return String(localized: "All Favorites", comment: "section header for list of existing FavoriteFoods")
        }
        else {
            return String(localized: "Not in a Folder", comment: "Section header for favorite foods that are not filed in a folder")
        }
    }

    private func emptyFolderRow(for section: FavoriteFoodSection) -> some View {
        Text("This folder is empty.", comment: "Placeholder row shown for a favorite food folder with no foods in it")
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.vertical, 6)
    }

    private func folderMenu(for folder: FavoriteFoodFolder) -> some View {
        Menu {
            Button(action: { viewModel.addFoodTapped(folderID: folder.id) }) {
                Label(String(localized: "Add Food Here", comment: "Menu action to add a favorite food directly into a folder"), systemImage: "plus")
            }

            Button(action: { viewModel.renameFolderTapped(folder) }) {
                Label(String(localized: "Edit Folder", comment: "Menu action to rename a favorite food folder"), systemImage: "pencil")
            }

            Button(role: .destructive, action: { viewModel.onFolderDelete(folder) }) {
                Label(String(localized: "Delete Folder", comment: "Menu action to delete a favorite food folder"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundColor(.accentColor)
                .textCase(nil)
        }
    }

    @ViewBuilder
    private func moveMenuItems(for food: StoredFavoriteFood) -> some View {
        if !viewModel.folders.isEmpty {
            Text("Move to", comment: "Header of the context menu used to file a favorite food into a folder")

            Button(action: { viewModel.moveFood(food, toFolderID: nil) }) {
                Label(String(localized: "No Folder", comment: "Folder picker option for a favorite food that is not in a folder"), systemImage: "tray")
            }

            ForEach(viewModel.folders) { folder in
                Button(action: { viewModel.moveFood(food, toFolderID: folder.id) }) {
                    Label(folder.title, systemImage: "folder")
                }
            }
        }
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Text("Done")
        }
    }
        
    private var editButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                editMode.toggle()
            }
        }) {
            Text(editMode.title)
                .textCase(nil)
        }
    }
    
    private var addFoodButton: some View {
        Button(action: { viewModel.addFoodTapped() }) {
            HStack {
                Image(systemName: "plus.circle.fill")
                
                Text("Add a new favorite food", comment: "Button label to open new favorite food view")
            }
        }
        .buttonStyle(ActionButtonStyle())
    }

    private var addFolderButton: some View {
        Button(action: viewModel.addFolderTapped) {
            HStack {
                Image(systemName: "folder.badge.plus")

                Text("Add a folder", comment: "Button label to create a new favorite food folder")
            }
        }
        .buttonStyle(ActionButtonStyle(.secondary))
        .padding(.top, 10)
    }
}

// MARK: - Folder editor

/// Create, rename or delete a favorite food folder.
struct FavoriteFoodFolderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existingFolder: FavoriteFoodFolder?
    private let onSave: (FavoriteFoodFolder) -> Void
    private let onDelete: (FavoriteFoodFolder) -> Void

    @State private var name: String
    @State private var emoji: String
    @State private var isConfirmingDelete = false

    init(folder: FavoriteFoodFolder?, onSave: @escaping (FavoriteFoodFolder) -> Void, onDelete: @escaping (FavoriteFoodFolder) -> Void) {
        self.existingFolder = folder
        self.onSave = onSave
        self.onDelete = onDelete
        self._name = State(initialValue: folder?.name ?? "")
        self._emoji = State(initialValue: folder?.emoji ?? "")
    }

    /// Not localized — an emoji reads the same in every language.
    private static let emojiPlaceholder = "🥣"

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("Name", comment: "Label for name row on add favorite food screen")
                        Spacer()
                        TextField(String(localized: "Breakfast", comment: "Placeholder name for a new favorite food folder"), text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Icon", comment: "Label for the optional emoji shown on a favorite food folder")
                        Spacer()
                        TextField(Self.emojiPlaceholder, text: $emoji)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: emoji) { newValue in
                                // A folder icon is a single character.
                                emoji = String(newValue.suffix(1))
                            }
                    }
                } footer: {
                    Text("Folders are optional. Deleting a folder keeps its foods — they simply move back out of the folder.", comment: "Footer explaining favorite food folders")
                }

                if let existingFolder {
                    Section {
                        Button(role: .destructive, action: { isConfirmingDelete = true }) {
                            Text("Delete Folder", comment: "Menu action to delete a favorite food folder")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .alert(isPresented: $isConfirmingDelete) {
                            Alert(
                                title: Text("Delete “\(existingFolder.name)”?"),
                                message: Text("The foods in this folder will be kept and moved out of the folder.", comment: "Message confirming deletion of a favorite food folder"),
                                primaryButton: .cancel(),
                                secondaryButton: .destructive(Text("Delete"), action: {
                                    onDelete(existingFolder)
                                    dismiss()
                                })
                            )
                        }
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationBarTitle(existingFolder == nil ? String(localized: "New Folder", comment: "Title of the new favorite food folder screen") : String(localized: "Edit Folder", comment: "Menu action to rename a favorite food folder"), displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: dismiss.callAsFunction) {
                        Text("Cancel")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: save) {
                        Text("Save")
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        var folder = existingFolder ?? FavoriteFoodFolder(name: trimmedName)
        folder.name = trimmedName
        folder.emoji = emoji
        onSave(folder)
        dismiss()
    }
}
