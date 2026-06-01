//
//  PodcastPreviewWidgetsExtensionBundle.swift
//  PodcastPreviewWidgetsExtension
//
//  Created by Chris Izatt on 20/04/2026.
//

import WidgetKit
import SwiftUI

@main
struct PodcastPreviewWidgetsExtensionBundle: WidgetBundle {
    var body: some Widget {
        PeriodicAveragesWidgetForiOS()
        ActivityHeatmapWidgetForiOS()
    }
}
