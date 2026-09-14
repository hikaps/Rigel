import Foundation

struct SubtitleInput {
    let sourceID: Int
    let context: UnsafeMutablePointer<AVFormatContext>
    let streamIndex: Int32
    let timeBase: AVRational
    let language: String?
    let title: String?
    /// Non-nil for external sidecar sources opened with an I/O watchdog;
    /// the reference must outlive the context because the C interrupt
    /// callback holds an unretained pointer.
    let ioWatchdog: InputWatchdog?
}

struct SubtitleCue {
    let startMs: Int64
    let endMs: Int64
    let text: String
}

final class SubtitleRendition {
    let input: SubtitleInput
    let ordinal: Int
    let playlistName: String
    let outDir: URL
    let chain: SubtitleChain?
    let language: String?
    let title: String?
    let isSelectedExternal: Bool
    var wrotePacket = false
    var decodeFailed = false
    var finished = false
    var nextSegmentIndex = 0
    var timelineEndMs: Int64 = 0
    var segments: [(name: String, duration: Double)] = []

    init(
        input: SubtitleInput,
        ordinal: Int,
        playlistName: String,
        outDir: URL,
        chain: SubtitleChain?,
        language: String?,
        title: String?,
        isSelectedExternal: Bool
    ) {
        self.input = input
        self.ordinal = ordinal
        self.playlistName = playlistName
        self.outDir = outDir
        self.chain = chain
        self.language = language
        self.title = title
        self.isSelectedExternal = isSelectedExternal
    }
}
final class SubtitleChain {
    let decCtx: UnsafeMutablePointer<AVCodecContext>

    init(decCtx: UnsafeMutablePointer<AVCodecContext>) {
        self.decCtx = decCtx
    }

    func release() {
        var dec: UnsafeMutablePointer<AVCodecContext>? = decCtx
        avcodec_free_context(&dec)
    }
}
