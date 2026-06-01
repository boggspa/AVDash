//
//  PodcastPreviewMacWidgetsExtensionBundle.swift
//  PodcastPreviewMacWidgetsExtension
//
//  Created by Chris Izatt on 20/04/2026.
//

import WidgetKit
import SwiftUI

@main
struct PodcastPreviewMacWidgetsExtensionBundle: WidgetBundle {
    var body: some Widget {
        PeriodicAveragesWidget()
        ActivityHeatmapWidget()
    }
}
