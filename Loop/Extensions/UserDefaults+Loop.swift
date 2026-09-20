//
//  UserDefaults+Loop.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit


extension UserDefaults {
    private enum Key: String {
        case legacyPumpManagerState = "com.loopkit.Loop.PumpManagerState"
        case legacyCGMManagerState = "com.loopkit.Loop.CGMManagerState"
        case legacyServicesState = "com.loopkit.Loop.ServicesState"
        case loopNotRunningNotifications = "com.loopkit.Loop.loopNotRunningNotifications"
        case inFlightAutomaticDose = "com.loopkit.Loop.inFlightAutomaticDose"
        case favoriteFoods = "com.loopkit.Loop.favoriteFoods"
        case favoriteFoodFolders = "com.loopkit.Loop.favoriteFoodFolders"
        case favoriteFoodTombstones = "com.loopkit.Loop.favoriteFoodTombstones"
    }

    var legacyPumpManagerRawValue: PumpManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyPumpManagerState.rawValue)
        }
    }
    func clearLegacyPumpManagerRawValue() {
        set(nil, forKey: Key.legacyPumpManagerState.rawValue)
    }


    var legacyCGMManagerRawValue: CGMManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyCGMManagerState.rawValue)
        }
    }

    func clearLegacyCGMManagerRawValue() {
        set(nil, forKey: Key.legacyCGMManagerState.rawValue)
    }

    var legacyServicesState: [Service.RawStateValue] {
        get {
            return array(forKey: Key.legacyServicesState.rawValue) as? [[String: Any]] ?? []
        }
    }

    func clearLegacyServicesState() {
        set(nil, forKey: Key.legacyServicesState.rawValue)
    }

    var inFlightAutomaticDose: AutomaticDoseRecommendation? {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.inFlightAutomaticDose.rawValue) as? Data else {
                return nil
            }
            return try? decoder.decode(AutomaticDoseRecommendation.self, from: data)
        }
        set {
            do {
                if let newValue = newValue {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(newValue)
                    set(data, forKey: Key.inFlightAutomaticDose.rawValue)
                } else {
                    set(nil, forKey: Key.inFlightAutomaticDose.rawValue)
                }
            } catch {
                assertionFailure("Unable to encode AutomaticDoseRecommendation")
            }
        }
    }

    var loopNotRunningNotifications: [StoredLoopNotRunningNotification] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.loopNotRunningNotifications.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredLoopNotRunningNotification].self, from: data)) ?? []
        }
        set {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(newValue)
                set(data, forKey: Key.loopNotRunningNotifications.rawValue)
            } catch {
                assertionFailure("Unable to encode Loop not running notification")
            }
        }
    }
    
    var favoriteFoods: [StoredFavoriteFood] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.favoriteFoods.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredFavoriteFood].self, from: data)) ?? []
        }
        set {
            // Every screen that edits favorites writes the whole list back through here, so this
            // is where an edit gets its timestamp and a removal leaves a tombstone behind. Both
            // are what lets Nightscout tell this phone's changes apart from the caregiver's.
            let stamped = FavoriteFoodEditJournal.stamp(newValue, previous: favoriteFoods)
            let tombstones = FavoriteFoodEditJournal.tombstones(
                previous: favoriteFoods,
                next: stamped,
                existing: favoriteFoodTombstones
            )

            writeFavoriteFoods(stamped)
            if tombstones != favoriteFoodTombstones {
                favoriteFoodTombstones = tombstones
            }

            NotificationCenter.default.post(name: .favoriteFoodsEditedLocally, object: nil)
        }
    }

    /// Favorites deleted here, kept until the deletion has reached Nightscout.
    var favoriteFoodTombstones: [FavoriteFoodTombstone] {
        get {
            guard let data = object(forKey: Key.favoriteFoodTombstones.rawValue) as? Data else {
                return []
            }
            return (try? JSONDecoder().decode([FavoriteFoodTombstone].self, from: data)) ?? []
        }
        set {
            do {
                set(try JSONEncoder().encode(newValue), forKey: Key.favoriteFoodTombstones.rawValue)
            } catch {
                assertionFailure("Unable to encode favorite food tombstones")
            }
        }
    }

    /// Stores what the Nightscout sync worked out, which already carries the right timestamps —
    /// stamping it again would make every sync look like a local edit.
    func applySyncedFavoriteFoods(foods: [StoredFavoriteFood], folders: [FavoriteFoodFolder], tombstones: [FavoriteFoodTombstone]) {
        writeFavoriteFoods(foods)
        // Written past the folder setter: a folder renamed on the other phone is not an edit
        // made here, and must not be stamped as one.
        if folders != favoriteFoodFolders {
            writeFavoriteFoodFolders(folders)
        }
        if tombstones != favoriteFoodTombstones {
            favoriteFoodTombstones = tombstones
        }
    }

    private func writeFavoriteFoods(_ foods: [StoredFavoriteFood]) {
        do {
            set(try JSONEncoder().encode(foods), forKey: Key.favoriteFoods.rawValue)
        } catch {
            assertionFailure("Unable to encode stored favorite foods")
        }
    }

    private func writeFavoriteFoodFolders(_ folders: [FavoriteFoodFolder]) {
        do {
            set(try JSONEncoder().encode(folders), forKey: Key.favoriteFoodFolders.rawValue)
        } catch {
            assertionFailure("Unable to encode favorite food folders")
        }
    }

    var favoriteFoodFolders: [FavoriteFoodFolder] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.favoriteFoodFolders.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([FavoriteFoodFolder].self, from: data)) ?? []
        }
        set {
            // Renaming a folder changes how its foods read, and a folder only travels to
            // Nightscout as part of them, so the rename rides along on the foods.
            let currentFoods = favoriteFoods
            let stampedFoods = FavoriteFoodEditJournal.stampFoods(
                currentFoods,
                inFoldersChangedFrom: favoriteFoodFolders,
                to: newValue
            )

            writeFavoriteFoodFolders(newValue)

            // `StoredFavoriteFood` compares by id alone, so the timestamps are checked directly.
            if zip(currentFoods, stampedFoods).contains(where: { $0.updatedAt != $1.updatedAt }) {
                writeFavoriteFoods(stampedFoods)
                NotificationCenter.default.post(name: .favoriteFoodsEditedLocally, object: nil)
            }
        }
    }
}
