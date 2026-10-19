//
//  PumpDeliveryAlertViews.swift
//  Loop
//
//  The pump delivery alert's settings: the switch, what it looks for, and the last alert.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

struct PumpDeliveryAlertSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    let manager: PumpDeliveryAlertManager?

    @State private var isEnabled = UserDefaults.standard.pumpDeliveryAlertEnabled
    private let last = UserDefaults.standard.pumpDeliveryAlertLast

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: $isEnabled) {
                        Text("Pump Delivery Alert", comment: "Switch for the alert when the pump may not be delivering insulin")
                    }
                } footer: {
                    Text("Alerts on this phone when glucose stays high and is not falling although the insulin given should have brought it down — the pod may not be delivering, for example a kinked cannula or a leak the pod does not alarm for.", comment: "Footer under the pump delivery alert switch")
                }

                Section {
                    rule(String(localized: "Glucose", comment: "Pump delivery alert rule: glucose"), String(format: String(localized: "At least %@", comment: "Pump delivery alert rule value (1: glucose)"), glucose(limits.glucose)))
                    rule(String(localized: "Unexplained Rise", comment: "Pump delivery alert rule: rise insulin and carbs do not explain"), String(format: String(localized: "At least %@", comment: "Pump delivery alert rule value (1: glucose)"), glucose(limits.unexplainedRise)))
                    rule(String(localized: "Insulin Given", comment: "Pump delivery alert rule: insulin acting"), String(format: String(localized: "Should lower by %@", comment: "Pump delivery alert rule value (1: glucose)"), glucose(limits.insulinDrop)))
                    rule(String(localized: "Persistent", comment: "Pump delivery alert rule: how long"), FatProteinBoostPlanner.hours(limits.persistent))
                } header: {
                    Text("When It Alerts", comment: "Header above the pump delivery alert's rules")
                } footer: {
                    Text("Insulin and carbs over the last 90 minutes are weighed with ISF and carb ratio. Glucose must not be falling, and every reading over the time must meet the limits. The same rules as LoopFollow's alert, set from 60 days of Nightscout history; after an alert, there is no new one for an hour.", comment: "Footer under the pump delivery alert's rules")
                }

                if let last {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(last.issued, style: .date) + Text(verbatim: " ") + Text(last.issued, style: .time)
                            Text(PumpDeliveryText.body(last.assessment, unit: displayGlucosePreference.unit))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Last Alert", comment: "Header above the last pump delivery alert")
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationTitle(Text("Pump Delivery Alert", comment: "Title of the pump delivery alert settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) { dismiss() }
                }
            }
            .onChange(of: isEnabled) { newValue in
                if let manager {
                    manager.isEnabled = newValue
                } else {
                    UserDefaults.standard.pumpDeliveryAlertEnabled = newValue
                }
            }
        }
    }

    private var limits: PumpDeliveryCheck.Limits { PumpDeliveryCheck.Limits() }

    private func glucose(_ mgdl: Double) -> String {
        PumpDeliveryText.glucose(mgdl, unit: displayGlucosePreference.unit)
    }

    private func rule(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}
