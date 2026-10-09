import Foundation

@main
enum TestSupportTests {
    static func main() {
        precondition(MusicTestInput.parse("  ") == nil)
        precondition(MusicTestInput.parse("  Pink Floyd  ") == .search("Pink Floyd"))
        precondition(MusicTestInput.parse("1440833097") == .songID("1440833097"))
        precondition(MusicTestInput.parse("https://music.apple.com/us/album/test/123?i=456") == .songID("456"))
        precondition(MusicTestInput.parse("https://music.apple.com/us/song/test/789") == .songID("789"))
        precondition(MusicTestInput.parse("https://music.apple.com/us/album/test/123") == .search("https://music.apple.com/us/album/test/123"))
        precondition(MusicTestInput.parse("https://example.com/song/test/789") == .search("https://example.com/song/test/789"))
        precondition(!AtmosEvidence.isConfirmed(isPlaying: false, activeVariant: "Dolby Atmos"))
        precondition(!AtmosEvidence.isConfirmed(isPlaying: true, activeVariant: "Lossless"))
        precondition(!AtmosEvidence.isConfirmed(isPlaying: true, activeVariant: nil))
        precondition(AtmosEvidence.isConfirmed(isPlaying: true, activeVariant: "Dolby Atmos"))
        precondition(AtmosEvidence.label(isPlaying: false, activeVariant: "Dolby Atmos") == "Waiting for playback")
        print("MusicKit input and active-Atmos evidence checks passed")
    }
}
