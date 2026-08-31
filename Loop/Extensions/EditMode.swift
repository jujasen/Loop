//
//  EditMode.swift
//  Loop
//
//  Created by Noah Brauner on 7/13/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI

extension EditMode {
    var title: String {
        self == .active
            ? String(localized: "Done", comment: "Title of the button that leaves list edit mode")
            : String(localized: "Edit", comment: "Title of the button that enters list edit mode")
    }
    
    mutating func toggle() {
        self = self == .active ? .inactive : .active
    }
}
