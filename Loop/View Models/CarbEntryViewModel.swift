//
//  CarbEntryViewModel.swift
//  Loop
//
//  Created by Noah Brauner on 7/21/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import HealthKit
import Combine

protocol CarbEntryViewModelDelegate: AnyObject, BolusEntryViewModelDelegate {
    var analyticsServicesManager: AnalyticsServicesManager { get }
    var defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes { get }
}

final class CarbEntryViewModel: ObservableObject {
    enum Alert: Identifiable {
        var id: Self {
            return self
        }
        
        case maxQuantityExceded
        case warningQuantityValidation
    }
    
    enum Warning: Identifiable {
        var id: Self {
            return self
        }
        
        var priority: Int {
            switch self {
            case .entryIsMissedMeal:
                return 1
            case .overrideInProgress:
                return 2
            }
        }
        
        case entryIsMissedMeal
        case overrideInProgress
    }
    
    @Published var alert: CarbEntryViewModel.Alert?
    @Published var warnings: Set<Warning> = []

    @Published var bolusViewModel: BolusEntryViewModel?
    
    let shouldBeginEditingQuantity: Bool
    
    @Published var carbsQuantity: Double? = nil
    var preferredCarbUnit = HKUnit.gram()
    var maxCarbEntryQuantity = LoopConstants.maxCarbEntryQuantity
    var warningCarbEntryQuantity = LoopConstants.warningCarbEntryQuantity
    
    @Published var time = Date()
    private var date = Date()
    var minimumDate: Date {
        get { date.addingTimeInterval(LoopConstants.maxCarbEntryPastTime) }
    }
    var maximumDate: Date {
        get { date.addingTimeInterval(LoopConstants.maxCarbEntryFutureTime) }
    }
    
    @Published var foodType = ""
    @Published var selectedDefaultAbsorptionTimeEmoji: String = ""
    @Published var usesCustomFoodType = false
    /// The dish's name, when a favorite food or an AI meal estimate filled in the entry. It is
    /// saved after the emoji in `foodType` (see `CarbFoodLabel`), so the chart can show it.
    @Published var foodName = ""
    @Published var absorptionTimeWasEdited = false // if true, selecting an emoji will not alter the absorption time
    private var absorptionEditIsProgrammatic = false // needed for when absorption time is changed due to favorite food selection, so that absorptionTimeWasEdited does not get set to true

    @Published var absorptionTime: TimeInterval
    let defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes
    let minAbsorptionTime = LoopConstants.minCarbAbsorptionTime
    let maxAbsorptionTime = LoopConstants.maxCarbAbsorptionTime
    var absorptionRimesRange: ClosedRange<TimeInterval> {
        return minAbsorptionTime...maxAbsorptionTime
    }
    
    @Published var favoriteFoods = UserDefaults.standard.favoriteFoods

    /// What happens later for this meal: `nil` for nothing, a plan without a rule when turned down.
    @Published var laterCarb: MealCarbFollowUp?
    /// What the favorite food or the meal estimate suggested, kept so a turned-down suggestion can
    /// be taken up again.
    @Published private(set) var laterCarbSuggestion: MealCarbFollowUp?
    @Published var favoriteFoodFolders = UserDefaults.standard.favoriteFoodFolders
    @Published var selectedFavoriteFoodIndex = -1
    /// `id` of the amount applied from the selected favorite food, for foods that have several.
    @Published var selectedPortionID: String? = nil

    /// Nil when the app was built without an OpenAI key; the meal estimate card is then hidden.
    let mealEstimator: MealCarbEstimator?
    @Published var mealDescription = ""
    @Published var mealFollowUp = ""
    /// Photos waiting to go with the next description or follow-up, already prepared for upload.
    @Published private(set) var mealPhotos: [Data] = []
    @Published private(set) var mealEstimate: MealCarbEstimate?
    @Published private(set) var isEstimatingMeal = false
    @Published var mealEstimateError: String?
    /// Everything said about this meal so far, so a follow-up re-evaluates the whole meal.
    private var mealConversation: [MealCarbEstimator.Message] = []
    private var mealEstimateTask: Task<Void, Never>?

    lazy var carbFormatter = QuantityFormatter(for: preferredCarbUnit)
    lazy var absorptionTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    
    weak var delegate: CarbEntryViewModelDelegate?
    
    private lazy var cancellables = Set<AnyCancellable>()
    
    /// Initalizer for when`CarbEntryView` is presented from the home screen
    init(delegate: CarbEntryViewModelDelegate, mealEstimator: MealCarbEstimator? = MealCarbEstimator.shared) {
        self.delegate = delegate
        self.mealEstimator = mealEstimator
        self.absorptionTime = delegate.defaultAbsorptionTimes.medium
        self.defaultAbsorptionTimes = delegate.defaultAbsorptionTimes
        self.shouldBeginEditingQuantity = true
        
        observeAbsorptionTimeChange()
        observeFavoriteFoodChange()
        observeLoopUpdates()
    }
    
    /// Initalizer for when`CarbEntryView` has an entry to edit
    init(delegate: CarbEntryViewModelDelegate, originalCarbEntry: StoredCarbEntry, mealEstimator: MealCarbEstimator? = MealCarbEstimator.shared) {
        self.delegate = delegate
        self.mealEstimator = mealEstimator
        self.originalCarbEntry = originalCarbEntry
        self.defaultAbsorptionTimes = delegate.defaultAbsorptionTimes

        self.carbsQuantity = originalCarbEntry.quantity.doubleValue(for: preferredCarbUnit)
        self.time = originalCarbEntry.startDate
        let label = CarbFoodLabel(foodType: originalCarbEntry.foodType)
        self.foodType = label.emoji
        self.foodName = label.name
        self.absorptionTime = originalCarbEntry.absorptionTime ?? .hours(3)
        self.absorptionTimeWasEdited = true
        self.usesCustomFoodType = true
        self.shouldBeginEditingQuantity = false

        if let id = originalCarbEntry.syncIdentifier {
            let suggestion = Self.favoriteLaterCarb(named: label.name)
            self.laterCarbSuggestion = suggestion
            self.laterCarb = UserDefaults.standard.carbFollowUpMealPlans[id] ?? suggestion
        }

        observeLoopUpdates()
    }
    
    var originalCarbEntry: StoredCarbEntry? = nil
    private var favoriteFood: FavoriteFood? = nil
    
    private var updatedCarbEntry: NewCarbEntry? {
        if let quantity = carbsQuantity, quantity != 0 {
            let savedFoodType = CarbFoodLabel(emoji: usesCustomFoodType ? foodType : selectedDefaultAbsorptionTimeEmoji, name: foodName).foodType
            if let o = originalCarbEntry, o.quantity.doubleValue(for: preferredCarbUnit) == quantity && o.startDate == time && CarbFoodLabel(foodType: o.foodType).foodType == savedFoodType && o.absorptionTime == absorptionTime {
                return nil  // No changes were made
            }
            
            return NewCarbEntry(
                date: date,
                quantity: HKQuantity(unit: preferredCarbUnit, doubleValue: quantity),
                startDate: time,
                foodType: savedFoodType,
                absorptionTime: absorptionTime
            )
        }
        else {
            return nil
        }
    }
    
    var saveFavoriteFoodButtonDisabled: Bool {
        get {
            if let carbsQuantity, 0...maxCarbEntryQuantity.doubleValue(for: preferredCarbUnit) ~= carbsQuantity, selectedFavoriteFoodIndex == -1 {
                return false
            }
            return true
        }
    }
    
    var continueButtonDisabled: Bool {
        get { updatedCarbEntry == nil }
    }
    
    // MARK: - Continue to Bolus and Carb Quantity Warnings
    func continueToBolus() {
        guard updatedCarbEntry != nil else {
            return
        }
        
        validateInputAndContinue()
    }
    
    private func validateInputAndContinue() {
        guard absorptionTime <= maxAbsorptionTime else {
            return
        }
        
        guard let carbsQuantity, carbsQuantity > 0 else { return }
        let quantity = HKQuantity(unit: preferredCarbUnit, doubleValue: carbsQuantity)
        if quantity.compare(maxCarbEntryQuantity) == .orderedDescending {
            self.alert = .maxQuantityExceded
            return
        }
        else if quantity.compare(warningCarbEntryQuantity) == .orderedDescending, selectedFavoriteFoodIndex == -1 {
            self.alert = .warningQuantityValidation
            return
        }
        
        Task { @MainActor in
            setBolusViewModel()
        }
    }
        
    @MainActor private func setBolusViewModel() {
        let viewModel = BolusEntryViewModel(
            delegate: delegate,
            screenWidth: UIScreen.main.bounds.width,
            originalCarbEntry: originalCarbEntry,
            potentialCarbEntry: updatedCarbEntry,
            selectedCarbAbsorptionTimeEmoji: selectedDefaultAbsorptionTimeEmoji
        )
        viewModel.laterCarbPlan = laterCarb
        Task {
            await viewModel.generateRecommendationAndStartObserving()
        }
        
        viewModel.analyticsServicesManager = delegate?.analyticsServicesManager
        bolusViewModel = viewModel
        
        delegate?.analyticsServicesManager.didDisplayBolusScreen()
    }
    
    func clearAlert() {
        self.alert = nil
    }
    
    func clearAlertAndContinueToBolus() {
        self.alert = nil
        Task { @MainActor in
            setBolusViewModel()
        }
    }
    
    // MARK: - Favorite Foods
    func onFavoriteFoodSave(_ food: NewFavoriteFood) {
        let newStoredFood = StoredFavoriteFood(name: food.name, portions: food.portions, foodType: food.foodType, absorptionTime: food.absorptionTime, folderID: food.folderID)
        favoriteFoods.append(newStoredFood)
        selectFavoriteFood(newStoredFood)
    }

    var selectedFavoriteFood: StoredFavoriteFood? {
        guard favoriteFoods.indices.contains(selectedFavoriteFoodIndex) else { return nil }
        return favoriteFoods[selectedFavoriteFoodIndex]
    }

    /// The amount applied from the selected food, when that food offers several.
    var selectedPortion: FavoriteFoodPortion? {
        selectedFavoriteFood?.portion(withID: selectedPortionID)
    }

    /// Selects a favorite food at one of its amounts, or clears the selection when passed `nil`.
    /// Passing no portion applies the food's first amount.
    func selectFavoriteFood(_ food: StoredFavoriteFood?, portion: FavoriteFoodPortion? = nil) {
        guard let food, let index = favoriteFoods.firstIndex(of: food) else {
            selectedFavoriteFoodIndex = -1
            selectedPortionID = nil
            applyClearedFavoriteFood()
            return
        }

        let portion = portion ?? food.defaultPortion
        selectedFavoriteFoodIndex = index
        selectedPortionID = portion.id
        apply(food: food, portion: portion)
    }

    /// Tapping the food and amount that is already applied clears it, so one control both applies
    /// and undoes. Picking a different amount of the same food just switches amount.
    func toggleFavoriteFood(_ food: StoredFavoriteFood, portion: FavoriteFoodPortion? = nil) {
        let portion = portion ?? food.defaultPortion
        if selectedFavoriteFood == food, selectedPortionID == portion.id {
            selectFavoriteFood(nil)
        }
        else {
            selectFavoriteFood(food, portion: portion)
        }
    }

    /// True when this exact food and amount is what the entry currently holds.
    func isSelected(_ food: StoredFavoriteFood, portion: FavoriteFoodPortion? = nil) -> Bool {
        guard selectedFavoriteFood == food else { return false }
        guard let portion else { return true }
        return selectedPortionID == portion.id
    }

    /// Favorite foods grouped for display: folders in their stored order, then unfiled foods.
    var favoriteFoodSections: [FavoriteFoodSection] {
        var sections = favoriteFoodFolders.map { folder in
            FavoriteFoodSection(folder: folder, foods: favoriteFoods.filter { $0.folderID == folder.id })
        }
        .filter { !$0.foods.isEmpty }

        let unfiled = favoriteFoods.filter { food in
            guard let folderID = food.folderID else { return true }
            return !favoriteFoodFolders.contains(where: { $0.id == folderID })
        }
        if !unfiled.isEmpty {
            sections.append(FavoriteFoodSection(folder: nil, foods: unfiled))
        }
        return sections
    }
    
    private func observeFavoriteFoodChange() {
        $favoriteFoods
            .dropFirst()
            .removeDuplicates()
            .sink { newValue in
                UserDefaults.standard.favoriteFoods = newValue
            }
            .store(in: &cancellables)
    }

    private func applyClearedFavoriteFood() {
        self.absorptionEditIsProgrammatic = true
        self.carbsQuantity = 0
        self.foodType = ""
        self.foodName = ""
        self.absorptionTime = defaultAbsorptionTimes.medium
        self.absorptionTimeWasEdited = false
        self.usesCustomFoodType = false
        setLaterCarbSuggestion(nil)
    }

    private func apply(food: StoredFavoriteFood, portion: FavoriteFoodPortion) {
        self.absorptionEditIsProgrammatic = true
        self.carbsQuantity = portion.carbsQuantity.doubleValue(for: preferredCarbUnit)
        self.foodType = food.foodType
        self.foodName = food.name
        self.absorptionTime = food.absorptionTime
        self.absorptionTimeWasEdited = true
        self.usesCustomFoodType = true
        setLaterCarbSuggestion(Self.favoriteLaterCarb(for: food))
    }

    // MARK: - Later Carbs

    /// The favorite food's later carbs, as they would apply to a meal of it.
    static func favoriteLaterCarb(for food: StoredFavoriteFood, defaults: UserDefaults = .standard) -> MealCarbFollowUp? {
        guard let rule = defaults.carbFollowUpRules[food.id] else { return nil }
        let assessment = defaults.carbFollowUpAssessments[food.id]
        let suggested = assessment?.userChanged == false && assessment?.suggestion == rule
        return MealCarbFollowUp(rule: rule, source: suggested ? .ai : .favorite, reason: suggested ? assessment?.reason : nil)
    }

    static func favoriteLaterCarb(named name: String, defaults: UserDefaults = .standard) -> MealCarbFollowUp? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let food = defaults.favoriteFoods.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return nil }
        return favoriteLaterCarb(for: food, defaults: defaults)
    }

    /// A new suggestion replaces whatever the meal had: it describes a different meal.
    private func setLaterCarbSuggestion(_ suggestion: MealCarbFollowUp?) {
        laterCarbSuggestion = suggestion
        laterCarb = suggestion
    }

    /// The meal's later carbs as changed in the editor. An entry that already exists keeps the
    /// change at once; a new one hands it to the bolus screen, which keeps it once the entry is saved.
    func setLaterCarb(_ plan: MealCarbFollowUp?) {
        laterCarb = plan
        if let id = originalCarbEntry?.syncIdentifier {
            UserDefaults.standard.setCarbFollowUpMealPlan(plan, forMeal: id)
        }
    }

    /// When the meal starts, for the editor's earliest and latest times.
    var laterCarbMealStart: Date {
        time
    }

    // MARK: - Meal Estimate
    var canEstimateMeal: Bool {
        !isEstimatingMeal && (!mealDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mealPhotos.isEmpty)
    }

    var canRefineMealEstimate: Bool {
        !isEstimatingMeal && mealEstimate != nil && (!mealFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mealPhotos.isEmpty)
    }

    var canAddMealPhoto: Bool {
        !isEstimatingMeal && mealPhotos.count < MealCarbEstimator.maxPhotosPerMessage
    }

    /// Photos behind the current estimate, counting every message of the conversation.
    var mealEstimatePhotoCount: Int {
        mealConversation.reduce(0) { $0 + $1.images.count }
    }

    func addMealPhoto(_ image: UIImage) {
        guard canAddMealPhoto, let photo = MealCarbEstimator.preparedPhoto(image) else { return }
        mealPhotos.append(photo)
    }

    func removeMealPhoto(at index: Int) {
        guard mealPhotos.indices.contains(index) else { return }
        mealPhotos.remove(at: index)
    }

    /// Starts a fresh estimate from the description and any photos, forgetting earlier follow-ups.
    func estimateMeal() {
        guard canEstimateMeal else { return }
        let description = mealDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        requestMealEstimate(conversation: [MealCarbEstimator.Message(
            role: "user",
            content: description.isEmpty ? "Estimate the meal in the photos." : description,
            images: mealPhotos
        )])
    }

    /// Adds what the caregiver forgot — in words, photos or both — and asks for a new estimate
    /// of the whole meal.
    func refineMealEstimate() {
        guard canRefineMealEstimate, let mealEstimate else { return }
        let followUp = mealFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        requestMealEstimate(conversation: mealConversation + [
            MealCarbEstimator.assistantMessage(for: mealEstimate),
            MealCarbEstimator.Message(
                role: "user",
                content: followUp.isEmpty ? "More photos of the same meal." : "More information about the same meal: \(followUp)",
                images: mealPhotos
            ),
        ])
    }

    /// Forgets the estimate. The fields it filled in stay as they are.
    func clearMealEstimate() {
        mealEstimateTask?.cancel()
        mealEstimateTask = nil
        isEstimatingMeal = false
        mealEstimate = nil
        mealEstimateError = nil
        mealConversation = []
        mealDescription = ""
        mealFollowUp = ""
        mealPhotos = []
        if selectedFavoriteFoodIndex == -1, laterCarbSuggestion?.source == .ai {
            setLaterCarbSuggestion(nil)
        }
    }

    private func requestMealEstimate(conversation: [MealCarbEstimator.Message]) {
        guard let mealEstimator else { return }
        mealEstimateTask?.cancel()
        isEstimatingMeal = true
        mealEstimateError = nil

        mealEstimateTask = Task { @MainActor [weak self] in
            do {
                let estimate = try await mealEstimator.estimate(conversation: conversation)
                guard let self, !Task.isCancelled else { return }
                self.mealConversation = conversation
                self.mealEstimate = estimate
                self.mealFollowUp = ""
                self.mealPhotos = []
                self.isEstimatingMeal = false
                self.apply(estimate)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isEstimatingMeal = false
                self.mealEstimateError = error.localizedDescription
            }
        }
    }

    func apply(_ estimate: MealCarbEstimate) {
        selectedFavoriteFoodIndex = -1
        selectedPortionID = nil
        absorptionEditIsProgrammatic = true
        carbsQuantity = estimate.roundedCarbs
        foodType = estimate.foodTypeEmoji
        foodName = estimate.name
        usesCustomFoodType = true
        absorptionTime = estimate.absorptionTime(in: absorptionRimesRange)
        absorptionTimeWasEdited = true
        setLaterCarbSuggestion(estimate.laterCarbRule.map { MealCarbFollowUp(rule: $0, source: .ai, reason: estimate.laterCarbs?.reason) })
    }

    // MARK: - Utility
    func restoreUserActivityState(_ activity: NSUserActivity) {
        if let entry = activity.newCarbEntry {
            time = entry.date
            carbsQuantity = entry.quantity.doubleValue(for: preferredCarbUnit)

            if let foodType = entry.foodType {
                let label = CarbFoodLabel(foodType: foodType)
                self.foodType = label.emoji
                self.foodName = label.name
                usesCustomFoodType = true
            }

            if let absorptionTime = entry.absorptionTime {
                self.absorptionTime = absorptionTime
                absorptionTimeWasEdited = true
            }
            
            if activity.entryisMissedMeal {
                warnings.insert(.entryIsMissedMeal)
            }
        }
    }
    
    private func observeLoopUpdates() {
        self.checkIfOverrideEnabled()
        NotificationCenter.default
            .publisher(for: .LoopDataUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkIfOverrideEnabled()
            }
            .store(in: &cancellables)
    }
    
    private func checkIfOverrideEnabled() {
        if let managerSettings = delegate?.settings,
           managerSettings.scheduleOverrideEnabled(at: Date()),
           let overrideSettings = managerSettings.scheduleOverride?.settings,
           overrideSettings.effectiveInsulinNeedsScaleFactor != 1.0 {
            self.warnings.insert(.overrideInProgress)
        }
        else {
            self.warnings.remove(.overrideInProgress)
        }
    }
    
    private func observeAbsorptionTimeChange() {
        $absorptionTime
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in
                if self?.absorptionEditIsProgrammatic == true {
                    self?.absorptionEditIsProgrammatic = false
                }
                else {
                    self?.absorptionTimeWasEdited = true
                }
            }
            .store(in: &cancellables)
    }
}
