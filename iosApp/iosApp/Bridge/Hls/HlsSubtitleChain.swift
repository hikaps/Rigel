import Foundation

struct SubtitleInput {
    let sourceID: Int
    let context: UnsafeMutablePointer<AVFormatContext>
    let streamIndex: Int32
    let timeBase: AVRational
    let language: String?
    let title: String?
}

final class SubtitleOutput {
    let input: SubtitleInput
    let ordinal: Int
    let outputStream: UnsafeMutablePointer<AVStream>
    let chain: SubtitleChain?
    let videoOrdinal: Int

    init(
        input: SubtitleInput,
        ordinal: Int,
        outputStream: UnsafeMutablePointer<AVStream>,
        chain: SubtitleChain?,
        videoOrdinal: Int
    ) {
        self.input = input
        self.ordinal = ordinal
        self.outputStream = outputStream
        self.chain = chain
        self.videoOrdinal = videoOrdinal
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
