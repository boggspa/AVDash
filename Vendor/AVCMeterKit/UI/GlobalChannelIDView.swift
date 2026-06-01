import SwiftUI

struct GlobalChannelIDView: View {
    @ObservedObject var logStore = GlobalChannelLogStore.shared
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Notifications:")
                    .font(.headline)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(logStore.logs, id: \.self) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry)
                                    .font(.body)
                                    .bold()
                                    .foregroundColor(.secondary)
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding()

            Button("✕") {
                presentationMode.wrappedValue.dismiss()
            }
            .buttonStyle(BorderlessButtonStyle())
            .padding([.top, .trailing], 8)
           // .offset(x: 125)
        }
        .frame(minWidth: 420, minHeight: 300)
    }
}


class GlobalChannelLogStore: ObservableObject {
    static let shared = GlobalChannelLogStore()

    @Published var logs: [String] = []

    func add(_ log: String) {
        DispatchQueue.main.async {
            self.logs.append(log)
            if self.logs.count > 100 {
                self.logs.removeFirst(self.logs.count - 100)
            }
        }
    }

    func allLogs() -> [String] {
        return logs
    }
}

@_cdecl("GlobalChannelLogStore_AddLog")
public func GlobalChannelLogStore_AddLog(_ message: UnsafePointer<CChar>?) {
    guard let cString = message, let swiftString = String(validatingUTF8: cString) else { return }
    let ignorePrefixes = [
        "[Mixer][Debug]",
        "[Mixer][Signal]"
    ]
    for prefix in ignorePrefixes {
        if swiftString.hasPrefix(prefix) {
            return // Ignore repetitive logs
        }
    }
    GlobalChannelLogStore.shared.add(swiftString)
}
