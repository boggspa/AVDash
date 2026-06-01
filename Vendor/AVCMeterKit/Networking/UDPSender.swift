//
//  UDPSender.swift
//  AVCMeter
//
//  Created by Chris Izatt on 18/06/2025.
//

import Foundation
import Network

class UDPSender {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "UDPSenderQueue")

    init(host: String, port: UInt16) {
        let parameters = NWParameters.udp
        let endpoint = NWEndpoint.Host(host)
        let port = NWEndpoint.Port(rawValue: port) ?? 5000

        connection = NWConnection(host: endpoint, port: port, using: parameters)
        connection?.start(queue: queue)

        print("[UDPSender] Initialized connection to \(host):\(port)")
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[UDPSender] Send error: \(error)")
            } else {
                print("[UDPSender] Sent \(data.count) bytes")
            }
        })
    }

    func close() {
        connection?.cancel()
        print("[UDPSender] Connection closed.")
    }
}
