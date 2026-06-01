///
///  MeterUpdateCoordinator.swift
///  AVCMeter
///
///  Created by Chris Izatt on 19/06/2025.
///

import Foundation
import Combine

class MeterUpdateCoordinator {
    static let shared = MeterUpdateCoordinator()
    private let timerQueue = DispatchQueue(label: "com.avcmeter.meter-update", qos: .userInitiated)
    private let tickSubject = PassthroughSubject<Date, Never>()
    private var dispatchTimer: DispatchSourceTimer?

    private init() {}

    var publisher: AnyPublisher<Date, Never> {
        tickSubject.eraseToAnyPublisher()
    }

    /// Starts the meter update loop with a given interval.
    ///
    /// This function initializes and starts a `DispatchSourceTimer` on a dedicated queue.
    /// The timer refreshes the shared meter cache and publishes ticks back to the main thread.
    ///
    /// - Parameter interval: The refresh interval in seconds. Defaults to 0.05s (20 FPS).
    func start(interval: TimeInterval = 0.05) {
        guard dispatchTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            MultiChannelRingBuffer.shared.updateCache()
            let tickDate = Date()
            DispatchQueue.main.async {
                self?.tickSubject.send(tickDate)
            }
        }
        dispatchTimer = timer
        timer.resume()
    }

    func stop() {
        dispatchTimer?.cancel()
        dispatchTimer = nil
    }
}
