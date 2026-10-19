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

    /// Carb entries from the last few hours, so the fat and protein boost can count earlier parts
    /// of the meal.
    func recentCarbEntries(completion: @escaping ([StoredCarbEntry]) -> Void)
}

extension CarbEntryViewModelDelegate {
    func recentCarbEntries(completion: @escaping ([StoredCarbEntry]) -> Void) {
        completion([])
    }
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

    /// What the fat and protein boost would do for this meal, or `nil` without any carbs yet.
    @Published private(set) var fatProteinBoost: FatProteinBoostPreview?
    /// True when the boost was turned off for this meal.
    @Published private(set) var isFatProteinBoostDeclined = false
    /// Fat and protein the meal estimate found or that were typed in, saved with the entry.
    private var mealNutrition: MealNutrition?
    /// Earlier entries that may be part of the same meal (porridge before the milk).
    private var recentCarbEntries: [StoredCarbEntry] = []

    /// Splits the bolus: part now, the rest later. Off unless turned on for this meal.
    @Published var isSplitBolusOn = false
    /// Share and delay changed by hand for this meal, `nil` for the suggested ones.
    @Published var splitChosenShare: Double?
    @Published var splitChosenDelay: TimeInterval?
    /// What the split would do for this meal, `nil` without any carbs or when it cannot split.
    @Published private(set) var splitBolus: SplitBolusSuggestion?
    /// The split whose rest this entry logs, when opened from its notification or card.
    @Published private(set) var splitRestPlan: SplitBolusPlan?
    /// A rest that is due and not logged yet, offered on a new entry's screen.
    @Published private(set) var dueSplitRest: SplitBolusPlan?
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
        observeFatProteinInputs()
        observeSplitBolusInputs()
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
            self.mealNutrition = UserDefaults.standard.mealNutrition[id]
            self.isFatProteinBoostDeclined = UserDefaults.standard.fatProteinBoostDeclined[id] != nil
        }

        observeLoopUpdates()
        observeFatProteinInputs()
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
    
    /// The entry handed to the bolus screen: with the bolus split, only the part eaten now, so
    /// Loop doses for that part and nothing more until the rest is logged.
    private var entryForBolus: NewCarbEntry? {
        guard let entry = updatedCarbEntry else { return nil }
        guard isSplitBolusOn, canSplitBolus, let split = splitBolus else { return entry }
        return NewCarbEntry(
            date: entry.date,
            quantity: HKQuantity(unit: .gram(), doubleValue: split.nowCarbs),
            startDate: entry.startDate,
            foodType: entry.foodType,
            absorptionTime: SplitBolusSettings.nowAbsorptionTime
        )
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
            potentialCarbEntry: entryForBolus,
            selectedCarbAbsorptionTimeEmoji: selectedDefaultAbsorptionTimeEmoji
        )
        viewModel.mealNutrition = mealNutrition
        viewModel.isFatProteinBoostDeclined = isFatProteinBoostDeclined
        viewModel.fatProteinBoost = isFatProteinBoostDeclined ? nil : fatProteinBoost
        if isSplitBolusOn, canSplitBolus, let splitBolus {
            // The rest already answers the late rise, so the boost stays out of this meal.
            viewModel.splitBolus = splitBolus
            viewModel.isFatProteinBoostDeclined = true
            viewModel.fatProteinBoost = nil
        }
        viewModel.splitRestPlan = splitRestPlan
        // The AI dose advice looks at the meal as it was described and photographed here.
        viewModel.aiDoseMealContext = AIDoseMealContext(
            conversation: mealConversation,
            foodName: foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : foodName
        )
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
        mealNutrition = nil
        updateFatProteinBoost()
    }

    private func apply(food: StoredFavoriteFood, portion: FavoriteFoodPortion) {
        self.absorptionEditIsProgrammatic = true
        self.carbsQuantity = portion.carbsQuantity.doubleValue(for: preferredCarbUnit)
        self.foodType = food.foodType
        self.foodName = food.name
        self.absorptionTime = food.absorptionTime
        self.absorptionTimeWasEdited = true
        self.usesCustomFoodType = true
        // The favorite's own fat and protein apply now, not what was found for another food.
        mealNutrition = nil
        updateFatProteinBoost()
    }

    // MARK: - Fat and Protein

    /// Works the meal's boost out again from what is on screen now, together with entries logged
    /// up to an hour before it.
    private func updateFatProteinBoost() {
        let carbs = carbsQuantity ?? 0
        guard carbs > 0 else {
            fatProteinBoost = nil
            return
        }

        let pendingID = "pending-fat-protein"
        let entry = StoredCarbEntry(
            startDate: time,
            quantity: HKQuantity(unit: .gram(), doubleValue: carbs),
            syncIdentifier: pendingID,
            foodType: CarbFoodLabel(emoji: foodType, name: foodName).foodType,
            absorptionTime: absorptionTime
        )
        let earlier = recentCarbEntries.filter { $0.startDate <= time && $0.syncIdentifier != originalCarbEntry?.syncIdentifier }

        let defaults = UserDefaults.standard
        var nutrition = defaults.mealNutrition
        nutrition[pendingID] = mealNutrition
        fatProteinBoost = FatProteinBoostPlanner.preview(
            entry: entry,
            earlier: earlier,
            favorites: favoriteFoods,
            assessments: defaults.favoriteNutritionAssessments,
            mealNutrition: nutrition,
            settings: defaults.fatProteinBoostSettings,
            factor: defaults.fatProteinBoostCalibration.factor
        )
    }

    private func observeFatProteinInputs() {
        delegate?.recentCarbEntries { [weak self] entries in
            DispatchQueue.main.async {
                self?.recentCarbEntries = entries
                self?.updateFatProteinBoost()
            }
        }

        Publishers.CombineLatest3($time, $carbsQuantity, $foodName)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateFatProteinBoost() }
            .store(in: &cancellables)
    }

    /// This entry's fat and protein as typed in on the boost sheet, and whether the boost is
    /// turned off for the meal. An entry that already exists keeps the change at once; a new one
    /// hands it to the bolus screen, which keeps it once the entry is saved.
    func setFatProtein(_ nutrition: MealNutrition?, declined: Bool) {
        mealNutrition = nutrition
        isFatProteinBoostDeclined = declined
        if let id = originalCarbEntry?.syncIdentifier {
            UserDefaults.standard.setMealNutrition(nutrition, forEntry: id)
            UserDefaults.standard.setFatProteinBoostDeclined(declined, forEntry: id)
        }
        updateFatProteinBoost()
    }

    // MARK: - Split Bolus

    /// Only a new meal can be split; the rest of a split, or an entry being edited, cannot.
    var canSplitBolus: Bool {
        originalCarbEntry == nil && splitRestPlan == nil
    }

    private var splitFoodType: String? {
        CarbFoodLabel(emoji: usesCustomFoodType ? foodType : selectedDefaultAbsorptionTimeEmoji, name: foodName).foodType
    }

    private func updateSplitBolus() {
        let carbs = carbsQuantity ?? 0
        guard canSplitBolus, carbs > 0, let manager = SplitBolusManager.current else {
            splitBolus = nil
            return
        }
        let (foodType, time, share, delay) = (splitFoodType, time, splitChosenShare, splitChosenDelay)
        // The history behind the suggestion is weeks of readings: worked through off the main queue.
        Task.detached(priority: .userInitiated) { [weak self] in
            let suggestion = await manager.suggestion(carbs: carbs, foodType: foodType, mealDate: time, chosenShare: share, chosenDelay: delay)
            await MainActor.run {
                guard let self, self.carbsQuantity == carbs, self.time == time else { return }
                self.splitBolus = suggestion
            }
        }
    }

    private func updateDueSplitRest() {
        dueSplitRest = originalCarbEntry == nil && splitRestPlan == nil ? SplitBolusManager.current?.dueRest : nil
    }

    private func observeSplitBolusInputs() {
        updateDueSplitRest()
        NotificationCenter.default.publisher(for: .splitBolusDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateDueSplitRest() }
            .store(in: &cancellables)

        Publishers.CombineLatest4($time, $carbsQuantity, $foodName, $foodType)
            .combineLatest(Publishers.CombineLatest3($isSplitBolusOn, $splitChosenShare, $splitChosenDelay))
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateSplitBolus() }
            .store(in: &cancellables)
    }

    /// Fills the entry in with a split's rest, so continuing logs it and doses for it.
    func useSplitRest(_ plan: SplitBolusPlan) {
        let entry = plan.laterEntry(at: Date())
        splitRestPlan = plan
        isSplitBolusOn = false
        dueSplitRest = nil
        selectedFavoriteFoodIndex = -1
        selectedPortionID = nil
        absorptionEditIsProgrammatic = true
        time = entry.startDate
        carbsQuantity = entry.quantity.doubleValue(for: preferredCarbUnit)
        let label = CarbFoodLabel(foodType: entry.foodType)
        foodType = label.emoji
        foodName = label.name
        usesCustomFoodType = true
        absorptionTime = entry.absorptionTime ?? SplitBolusSettings.laterAbsorptionTime
        absorptionTimeWasEdited = true
        mealNutrition = nil
        splitBolus = nil
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
        mealNutrition = estimate.nutrition
        updateFatProteinBoost()
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
        if let id = activity.userInfo?[SplitBolusManager.planIDUserInfoKey] as? String,
           let plan = SplitBolusManager.current?.plan(withID: id), plan.isOpen {
            useSplitRest(plan)
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
