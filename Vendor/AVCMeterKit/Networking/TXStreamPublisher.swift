//
//  TXStreamPublisher.swift
//  AVCMeter
//
//  Created by Chris Izatt on 13/06/2025.
//


import Foundation
import Network

class TXStreamPublisher {
    private var connection: NWConnection?
    private var queue = DispatchQueue(label: "TXStreamPublisherQueue")
    private var isTransmitting = false
    private var timer: DispatchSourceTimer?
    private let buffer: RingBuffer
    private let remoteHost: NWEndpoint.Host
    private let remotePort: NWEndpoint.Port

    init(buffer: RingBuffer, host: String, port: UInt16) {
        self.buffer = buffer
        self.remoteHost = NWEndpoint.Host(host)
        self.remotePort = NWEndpoint.Port(rawValue: port)!
    }



    func stop() {
        isTransmitting = false
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
    }

}
