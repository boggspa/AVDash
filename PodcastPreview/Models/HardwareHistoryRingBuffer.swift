//
//  HardwareHistoryRingBuffer.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 14/03/2026.
//

import Foundation

struct HardwareHistoryRingBuffer<Element> {
    private var storage: [Element?]
    private var writeIndex: Int = 0
    private(set) var count: Int = 0

    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: nil, count: self.capacity)
    }

    mutating func append(_ element: Element) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity {
            count += 1
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }

    func values() -> [Element] {
        guard count > 0 else { return [] }

        let start = count == capacity ? writeIndex : 0
        var result: [Element] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let index = (start + i) % capacity
            if let value = storage[index] {
                result.append(value)
            }
        }

        return result
    }

    func recentValues(limit: Int) -> [Element] {
        let all = values()
        guard all.count > limit else { return all }
        return Array(all.suffix(limit))
    }
}
