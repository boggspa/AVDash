//
//  NetworkTargetView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 18/06/2025.
//

import SwiftUI

struct NetworkTarget: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var ipAddress: String
    var port: Int
    var isActive: Bool
}

struct NetworkTargetView: View {
    @State private var targets: [NetworkTarget] = [
        NetworkTarget(name: "Loopback", ipAddress: "127.0.0.1", port: 5050, isActive: false),
        NetworkTarget(name: "Tailscale Remote", ipAddress: "100.120.5.1", port: 5050, isActive: true)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network Targets")
                .font(.headline)

            List {
                ForEach($targets) { $target in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(target.name)
                                .font(.subheadline)
                            Text("\(target.ipAddress):\(target.port)")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }

                        Spacer()

                        Toggle("Active", isOn: $target.isActive)
                            .labelsHidden()
                    }
                }
                .onDelete(perform: deleteTarget)
            }

            Button(action: addTarget) {
                Label("Add Target", systemImage: "plus")
            }
            .padding(.top, 8)
        }
        .padding()
    }

    private func deleteTarget(at offsets: IndexSet) {
        targets.remove(atOffsets: offsets)
    }

    private func addTarget() {
        targets.append(NetworkTarget(name: "New Target", ipAddress: "0.0.0.0", port: 5050, isActive: false))
    }
}

#Preview {
    NetworkTargetView()
}
