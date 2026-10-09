//
//  CGMStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

public final class CGMStatusHUDView: DeviceStatusHUDView, NibLoadable {
    
    private var viewModel: CGMStatusHUDViewModel!

    /// Ticks the glucose age under the glucose value while the view is on screen.
    private var glucoseAgeTimer: Timer?
    
    @IBOutlet public weak var glucoseValueHUD: GlucoseValueHUDView!
    
    @IBOutlet public weak var glucoseTrendHUD: GlucoseTrendHUDView!
    
    override public var orderPriority: HUDViewOrderPriority {
        return 1
    }
    
    public var isVisible: Bool {
        get {
            viewModel.isVisible
        }
        set {
            if viewModel.isVisible != newValue {
                viewModel.isVisible = newValue
            }
        }
    }
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    override func setup() {
        super.setup()
        statusHighlightView.setIconPosition(.right)
        viewModel = CGMStatusHUDViewModel(staleGlucoseValueHandler: { [weak self] in
            self?.updateDisplay()
        })
    }
    
    deinit {
        glucoseAgeTimer?.invalidate()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        glucoseAgeTimer?.invalidate()
        glucoseAgeTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateGlucoseAge()
        }
        RunLoop.main.add(timer, forMode: .common)
        glucoseAgeTimer = timer
        updateGlucoseAge()
    }

    override public func tintColorDidChange() {
        super.tintColorDidChange()
        
        glucoseValueHUD.tintColor = viewModel.glucoseValueTintColor
        glucoseTrendHUD.tintColor = viewModel.glucoseTrendTintColor
    }

    override public func presentStatusHighlight(_ statusHighlight: DeviceStatusHighlight?) {
        viewModel.statusHighlight = statusHighlight
        super.presentStatusHighlight(viewModel.statusHighlight)
    }
    
    override func presentStatusHighlight() {
        defer {
            // when the status highlight is updated, the trend icon may also need to be updated
            updateTrendIcon()
            // when the status highlight is updated, the accessibility string is updated
            accessibilityValue = viewModel.accessibilityString
        }
        
        guard statusStackView.arrangedSubviews.contains(glucoseValueHUD),
            statusStackView.arrangedSubviews.contains(glucoseTrendHUD) else
        {
            return
        }
        
        // need to also hide these view, since they will be added back to the stack at some point
        glucoseValueHUD.isHidden = true
        glucoseTrendHUD.isHidden = true
        statusStackView.removeArrangedSubview(glucoseValueHUD)
        statusStackView.removeArrangedSubview(glucoseTrendHUD)
        
        super.presentStatusHighlight()
    }
    
    override public func dismissStatusHighlight() {
        defer {
            // when the status highlight is updated, the trend icon may also need to be updated
            updateTrendIcon()
            // when the status highlight is updated, the accessibility string is updated
            accessibilityValue = viewModel.accessibilityString
        }
        
        guard statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }

        super.dismissStatusHighlight()
        
        statusStackView.addArrangedSubview(glucoseValueHUD)
        statusStackView.addArrangedSubview(glucoseTrendHUD)
        glucoseValueHUD.isHidden = false
        glucoseTrendHUD.isHidden = false
    }
        
    public func setGlucoseQuantity(_ glucoseQuantity: Double,
                                   at glucoseStartDate: Date,
                                   unit: HKUnit,
                                   staleGlucoseAge: TimeInterval,
                                   glucoseDisplay: GlucoseDisplayable?,
                                   wasUserEntered: Bool,
                                   isDisplayOnly: Bool)
    {
        viewModel.setGlucoseQuantity(glucoseQuantity,
                                     at: glucoseStartDate,
                                     unit: unit,
                                     staleGlucoseAge: staleGlucoseAge,
                                     glucoseDisplay: glucoseDisplay,
                                     wasUserEntered: wasUserEntered,
                                     isDisplayOnly: isDisplayOnly)
        
        updateDisplay()
    }

    func updateDisplay() {
        glucoseValueHUD.glucoseLabel.text = viewModel.glucoseValueString
        updateGlucoseAge()
        glucoseValueHUD.tintColor = viewModel.glucoseValueTintColor
        presentStatusHighlight(viewModel.statusHighlight)
        
        accessibilityValue = viewModel.accessibilityString
    }
    
    /// Shows how long ago the glucose was measured under the glucose value, as LoopFollow does,
    /// or the glucose unit before there is a reading.
    private func updateGlucoseAge() {
        guard viewModel.isVisible else { return }
        let text = viewModel.glucoseAgeString() ?? viewModel.unitsString
        if glucoseValueHUD.unitLabel.text != text {
            glucoseValueHUD.unitLabel.text = text
        }
    }

    func updateTrendIcon() {
        glucoseTrendHUD.setIcon(viewModel.glucoseTrendIcon)
        glucoseTrendHUD.tintColor = viewModel.glucoseTrendTintColor
    }
}
