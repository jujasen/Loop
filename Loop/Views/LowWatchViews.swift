//
//  LowWatchViews.swift
//  Loop
//
//  The low watch's card on the home screen and its settings.
//

import LoopKitUI
import SwiftUI

/// An open suggestion of fast carbs with its buttons.
struct LowWatchCard: View {
    let action: LowWatchAction
    var onEnter: (LowWatchAction) -> Void
    var onDecline: (LowWatchAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LowWatchText.title(action))
                .font(.headline)
            Text(LowWatchText.reason(action))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    onEnter(action)
                } label: {
                    Text(LowWatchText.enter(action))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.carbTintColor)

                Button(role: .destructive) {
                    onDecline(action)
                } label: {
                    Text("Decline", comment: "Button declining the meal watch suggestion")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Text("Give the carbs first, then enter them. Stays until carbs are entered, here or in LoopFollow, or glucose comes back up.", comment: "Low watch card: what to do and how long it stays")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct LowWatchSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = LowWatchManager.shared
    @State private var settings = LowWatchManager.shared.settings

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: $settings.isOn) {
                        Text("Suggest Fast Carbs", comment: "Low watch: turn it on")
                    }
                    Toggle(isOn: $settings.soundAtNight) {
                        Text("Sound at Night", comment: "Low watch: the notification on this phone makes a sound between 21 and 07 too")
                    }
                } footer: {
                    Text("When Loop forecasts glucose under 3.9 within 20 minutes, or it is under 4.4 and falling, it suggests 2–6 g of fast carbs, around the clock, here and in LoopFollow. It never enters anything itself. By day the notification here makes a sound; from 21 to 07 only with Sound at Night.", comment: "Low watch settings: what it does")
                }

                Section {
                    Text("Nothing within 20 minutes of carbs being entered, or of the last suggestion. The grams lift Loop's lowest forecast within an hour to 5.5, at 0.7 mmol/L a gram. Over six weeks in autumn 2026 it would have warned before 23 of 26 lows, a median of 15 minutes ahead, 2.5 times a day; about once a day no low followed.", comment: "Low watch settings: the fixed rules and how they were chosen")
                        .font(.footnote)
                } header: {
                    Text("Always", comment: "Evening watch settings header above the fixed rules")
                }

                if !manager.state.actions.isEmpty {
                    Section {
                        ForEach(manager.state.actions.reversed()) { action in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(action.date, style: .date) + Text(verbatim: " ") + Text(action.date, style: .time)
                                    Spacer()
                                    Text(LowWatchText.state(action)).foregroundColor(.secondary)
                                }
                                Text(verbatim: LowWatchText.title(action) + " " + LowWatchText.reason(action))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Last Seven Days", comment: "Low watch settings: header above its suggestions")
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationTitle(Text(verbatim: LowWatchText.symbol + " " + LowWatchText.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) { dismiss() }
                }
            }
            .onChange(of: settings) { newValue in
                manager.update(newValue)
            }
        }
    }
}
