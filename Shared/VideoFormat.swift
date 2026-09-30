import CoreMedia
import Foundation

/// Turning wire payloads back into CMSampleBuffers, shared by the iPad view and the probe.
enum VideoFormat {
    static func description(codec: VideoCodec, parameterSets sets: [Data]) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        // Each Data must stay alive while its pointer is used, so pin them all first.
        let buffers = sets.map { [UInt8]($0) }
        let status: OSStatus = withPointers(buffers) { ptrs in
            let sizes = buffers.map(\.count)
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            }
        }
        return status == noErr ? desc : nil
    }

    /// Parameter sets of an encoder's output format, in the order the decoder wants them.
    static func parameterSets(of format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var count = 0
        let get: (Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>?) -> OSStatus = { i, p, n, c in
            switch codec {
            case .h264: CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: p,
                                                                          parameterSetSizeOut: n, parameterSetCountOut: c, nalUnitHeaderLengthOut: nil)
            case .hevc: CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: p,
                                                                          parameterSetSizeOut: n, parameterSetCountOut: c, nalUnitHeaderLengthOut: nil)
            }
        }
        var p: UnsafePointer<UInt8>?, n = 0
        guard get(0, &p, &n, &count) == noErr else { return [] }
        return (0..<count).compactMap { i in
            guard get(i, &p, &n, nil) == noErr, let p else { return nil }
            return Data(bytes: p, count: n)
        }
    }

    /// `data` is length-prefixed NAL units for one access unit.
    static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription, displayImmediately: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }

        if displayImmediately,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

private func withPointers<R>(_ buffers: [[UInt8]], _ body: ([UnsafePointer<UInt8>]) -> R) -> R {
    func go(_ i: Int, _ acc: [UnsafePointer<UInt8>]) -> R {
        if i == buffers.count { return body(acc) }
        return buffers[i].withUnsafeBufferPointer { go(i + 1, acc + [$0.baseAddress!]) }
    }
    return go(0, [])
}
