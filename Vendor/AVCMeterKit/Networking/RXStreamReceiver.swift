//
//  RXStreamReceiver.swift
//  AVCMeter
//
//  Created by Chris Izatt on 13/06/2025.
//

import Foundation
import Network

class RXStreamReceiver {
    private var listener: NWListener?
    private let port: NWEndpoint.Port
    private let buffer: RingBuffer
    private let numChannels: Int
    private let frameSize: Int

    init(port: UInt16, buffer: RingBuffer, numChannels: Int) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.buffer = buffer
        self.numChannels = numChannels
        self.frameSize = MemoryLayout<Float>.size * numChannels
    }

}
