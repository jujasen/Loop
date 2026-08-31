//
//  FavoriteFoodDetailView.swift
//  Loop
//
//  Created by Noah Brauner on 8/2/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit

public struct FavoriteFoodDetailView: View {
    @Environment(\.carbTintColor) private var carbTintColor

    let food: StoredFavoriteFood?
    let folderTitle: String?
    let onFoodDelete: (StoredFavoriteFood) -> Void
    
    @State private var isConfirmingDelete = false
    
    let carbFormatter: QuantityFormatter
    let absorptionTimeFormatter: DateComponentsFormatter
    let preferredCarbUnit: HKUnit
    
    public init(food: StoredFavoriteFood?, folderTitle: String? = nil, onFoodDelete: @escaping (StoredFavoriteFood) -> Void, isConfirmingDelete: Bool = false, carbFormatter: QuantityFormatter, absorptionTimeFormatter: DateComponentsFormatter, preferredCarbUnit: HKUnit = HKUnit.gram()) {
        self.food = food
        self.folderTitle = folderTitle
        self.onFoodDelete = onFoodDelete
        self.isConfirmingDelete = isConfirmingDelete
        self.carbFormatter = carbFormatter
        self.absorptionTimeFormatter = absorptionTimeFormatter
        self.preferredCarbUnit = preferredCarbUnit
    }
    
    public var body: some View {
        if let food {
            List {
                Section {
                    header(for: food)
                }
                .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))

                Section("Information") {
                    ForEach(rows(for: food), id: \.field) { row in
                        HStack {
                            Text(row.field)
                                .font(.subheadline)
                            Spacer()
                            Text(row.value)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                Button(role: .destructive, action: { isConfirmingDelete.toggle() }) {
                    Text("Delete Food")
                        .frame(maxWidth: .infinity, alignment: .center) // Align text in center
                }
            }
            .alert(isPresented: $isConfirmingDelete) {
                Alert(
                    title: Text("Delete “\(food.name)”?"),
                    message: Text("Are you sure you want to delete this food?"),
                    primaryButton: .cancel(),
                    secondaryButton: .destructive(Text("Delete"), action: { onFoodDelete(food) })
                )
            }
            .insetGroupedListStyle()
            .navigationTitle(food.name)
        }
    }

    private func header(for food: StoredFavoriteFood) -> some View {
        HStack(spacing: 14) {
            FavoriteFoodEmojiTile(emoji: food.foodType, tint: carbTintColor, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(food.name)
                    .font(.title3.weight(.semibold))

                if food.hasServingSize {
                    Text(food.servingSize)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Text(FavoriteFoodSummary.carbsAndAbsorption(for: food, carbFormatter: carbFormatter, absorptionTimeFormatter: absorptionTimeFormatter))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func rows(for food: StoredFavoriteFood) -> [(field: String, value: String)] {
        var rows: [(field: String, value: String)] = [
            (String(localized: "Name", comment: "Label for name row on add favorite food screen"), food.name)
        ]

        if food.hasServingSize {
            rows.append((String(localized: "Serving Size", comment: "Label for the free-text serving size row on add favorite food screen"), food.servingSize))
        }

        rows.append(contentsOf: [
            (String(localized: "Carb Quantity", comment: "Label for carb quantity row on add favorite food screen"), food.carbsString(formatter: carbFormatter)),
            (String(localized: "Food Type", comment: "Label for food type entry on add favorite food screen"), food.foodType),
            (String(localized: "Absorption Time", comment: "Label for food absorption entry on add favorite food screen"), food.absorptionTimeString(formatter: absorptionTimeFormatter))
        ])

        if let folderTitle {
            rows.append((String(localized: "Folder", comment: "Label for the folder row on add favorite food screen"), folderTitle))
        }

        return rows
    }
}
