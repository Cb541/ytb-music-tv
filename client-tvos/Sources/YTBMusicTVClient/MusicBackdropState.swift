import Foundation

// A late frame or still-cover request must never overwrite the next song.
struct MusicBackdropState {
    private(set) var generation = UUID()
    private(set) var hasLiveFrame = false

    mutating func begin() -> UUID {
        generation = UUID()
        hasLiveFrame = false
        return generation
    }

    mutating func acceptLive(_ token: UUID) -> Bool {
        guard token == generation else { return false }
        hasLiveFrame = true
        return true
    }

    func acceptsStill(_ token: UUID) -> Bool {
        token == generation && !hasLiveFrame
    }
}

// Use elapsed presentation time so 60 fps makes smaller steps, not faster
// movement. Pausing resets the timestamp without resetting the visible phase.
struct MusicBackdropClock {
    private(set) var phase = 0.0
    private var previousTime: Double?

    mutating func advance(to time: Double) {
        guard time.isFinite else { return }
        if let previousTime {
            phase += min(0.1, max(0, time - previousTime)) * 0.28 * 1.38
        }
        previousTime = time
    }

    mutating func pause() { previousTime = nil }
}
