//
//  NotificationCapsule.swift
//  AVCMeter
//
//  Created by Chris Izatt on 11/07/2025.
//

import Foundation
import SwiftUI

final class NotificationCapsule: ObservableObject {
    static let shared = NotificationCapsule()

    @Published var message: String = ""
    @Published var isVisible: Bool = false

    private init() {}

    static func show(_ message: String, duration: TimeInterval = 3.0) {
        DispatchQueue.main.async {
            shared.message = message
            shared.isVisible = true

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                shared.isVisible = false
            }
        }
    }
}

struct NotificationCapsuleView: View {
    @ObservedObject var capsule = NotificationCapsule.shared

    var body: some View {
        if capsule.isVisible {
            Text(capsule.message)
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.85))
                .foregroundColor(.white)
                .cornerRadius(12)
                .transition(.opacity)
                .zIndex(999)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 100)
        }
    }
}
