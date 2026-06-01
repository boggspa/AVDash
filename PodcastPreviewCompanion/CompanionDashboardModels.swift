import Foundation
import CloudKit
import SwiftUI
import PodcastPreviewCore

// This file now primarily provides backward compatibility for the companion app
// by type-aliasing or re-exporting from PodcastPreviewCore.
// Most logic has moved to PodcastPreviewCore for sharing with the main app.

typealias CompanionMachineIdentity = RemoteMachineIdentity
