//
//  FeaturesBlock.swift
//  AdaptySDK
//
//  Created by Aleksei Valiano on 29.06.2023
//

import Foundation

extension AdaptyUI {
    public struct FeaturesBlock {
        public let type: FeaturesBlockType
        public let items: [String: AdaptyUI.LocalizedViewItem]
    }

    public enum FeaturesBlockType: String {
        case list
        case timeline
    }
}
