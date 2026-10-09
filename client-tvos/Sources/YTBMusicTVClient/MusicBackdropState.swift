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
