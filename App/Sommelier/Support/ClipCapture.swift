// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import SommelierKit
import VideoToolbox

/// Records one game's window into a ring of compressed video and the game's sound (ScreenCaptureKit → the Mac's
/// hardware encoder → `ReplayRing`), and writes the last stretch out as an MP4 without compressing the picture
/// again. It holds no clip until `write` is asked: everything older than the ring's length is dropped as it goes.
final class ClipCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: Error { case noVideo, writerFailed(String) }

    let gameID: String
    let title: String
    let pid: Int32
    private(set) var settings: ClipSettings
    private(set) var pixelSize = CGSize.zero
    private let lock = NSLock()
    private var ring: ReplayRing<CMSampleBuffer>
    private var stream: SCStream?
    private var tap: ProcessAudioTap?
    private var encoder: VTCompressionSession?
    private var encoderSize = CGSize.zero
    private var inFlight = 0
    private var stopped = false
    private var firstAudio: Double?
    private var audioOffset: Double?
    private var heardSound = false
    private var lastVideo = Date()
    private let queue = DispatchQueue(label: "gg.sommelier.clips.capture", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "gg.sommelier.clips.audio", qos: .userInitiated)

    /// Called once when the stream ends (the window closed, the Mac slept, the system stopped it).
    var onEnded: (@Sendable (Error?) -> Void)?

    init(gameID: String, title: String, pid: Int32, settings: ClipSettings) {
        self.gameID = gameID; self.title = title; self.pid = pid; self.settings = settings
        ring = ReplayRing(keeps: settings.length.seconds + 2)
    }

    // MARK: Start and stop

    /// Starts on the window; the sound comes from the processes `soundOf` play through (a Core Audio tap), or,
    /// when that can't be had, from ScreenCaptureKit's own idea of the window's app.
    func start(window: SCWindow, soundOf pids: [pid_t] = []) async throws {
        var tapped = false
        if settings.gameSound, !pids.isEmpty {
            let tap = ProcessAudioTap()
            do {
                try tap.start(pids: pids) { [weak self] sample in self?.keepSound(sample) }
                lock.withLock { self.tap = tap }
                tapped = true
                Self.log?("sound tapped from \(pids.count) process(es): \(tap.formatText)")
            } catch {
                Self.log?("sound tap failed (\(error)); using the screen capture's sound")
            }
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, Double(filter.pointPixelScale))
        var width = Double(filter.contentRect.width) * scale
        var height = Double(filter.contentRect.height) * scale
        let profile = settings.quality.profile
        if let maxHeight = profile.maxHeight, height > Double(maxHeight) {
            width *= Double(maxHeight) / height
            height = Double(maxHeight)
        }
        // Even sizes: the encoder wants them.
        let size = CGSize(width: max(2, (width / 2).rounded(.down) * 2), height: max(2, (height / 2).rounded(.down) * 2))
        pixelSize = size

        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(profile.fps))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 6
        if settings.gameSound, !tapped {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.gameSound, !tapped { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        lock.withLock { self.stream = stream; stopped = false }
        do { try await stream.startCapture() } catch { lock.withLock { self.tap?.stop(); self.tap = nil }; throw error }
    }

    /// Stops capturing; what is in the ring stays until the capture is let go.
    func stop() async {
        let (stream, tap): (SCStream?, ProcessAudioTap?) = lock.withLock {
            let current = (self.stream, self.tap)
            self.stream = nil
            self.tap = nil
            stopped = true
            return current
        }
        tap?.stop()
        try? await stream?.stopCapture()
        closeEncoder()
    }

    var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return stream != nil && !stopped }

    /// Seconds since a picture last arrived (a hung or minimised game sends none).
    var quietFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastVideo) }

    var hasVideo: Bool { lock.lock(); defer { lock.unlock() }; return !ring.isEmpty }

    /// Whether any sound has been heard (a ring of silence means the game's sound didn't reach the recording).
    var soundArrived: Bool { lock.lock(); defer { lock.unlock() }; return heardSound }

    /// Whether sound was asked for and it's been long enough to know it isn't coming.
    var soundMissing: Bool {
        lock.lock(); defer { lock.unlock() }
        guard settings.gameSound else { return false }
        guard !heardSound else { return false }
        guard let first = firstAudio else { return Date().timeIntervalSince(lastVideo) < 1 ? false : ring.duration > 10 }
        return (ring.pieces.last?.time ?? first) - first > 10
    }

    func setLength(_ length: ClipSettings.Length) {
        lock.lock(); ring.setKeeps(length.seconds + 2); settings.length = length; lock.unlock()
    }

    // MARK: Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: encode(sampleBuffer)
        case .audio: keepSound(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); let already = stopped; stopped = true; self.stream = nil; let tap = self.tap; self.tap = nil; lock.unlock()
        tap?.stop()
        closeEncoder()
        Self.log?("stream of \(title) (pid \(pid)) stopped: \(error.localizedDescription) [\((error as NSError).code)]")
        if !already { onEnded?(error) }
    }

    private func encode(_ sample: CMSampleBuffer) {
        // Only frames with a new picture: ScreenCaptureKit also reports idle, blank and suspended ones.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        lock.lock()
        if stopped { lock.unlock(); return }
        lastVideo = Date()
        if encoder == nil || encoderSize != size {
            // The picture changed size (the window did): what was kept can't be joined to what comes now.
            if encoder != nil { ring.clear() }
            if let old = encoder { VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(old) }
            encoder = Self.makeEncoder(size: size, profile: settings.quality.profile)
            encoderSize = size
            inFlight = 0                     // the old session's frames are done with (completed or thrown away)
            Self.log?("encoder \(encoder == nil ? "failed" : "ready") for \(Int(size.width))×\(Int(size.height))")
        }
        guard let encoder, inFlight < 8 else { lock.unlock(); return }          // the encoder is behind: this frame is skipped
        inFlight += 1
        lock.unlock()

        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
                                                     frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, buffer in
            guard let self else { return }
            self.lock.lock()
            self.inFlight -= 1
            if status == noErr, let buffer, CMSampleBufferDataIsReady(buffer) {
                let notSync = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]])?
                    .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                self.ring.append(.init(time: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)), isVideo: true,
                                       isKeyFrame: !notSync, bytes: CMSampleBufferGetTotalSampleSize(buffer), payload: buffer))
            }
            self.lock.unlock()
        }
        if status != noErr {
            // The frame was refused on the spot: the handler won't come for it.
            lock.lock(); inFlight -= 1; lock.unlock()
            Self.log?("encode refused: \(status)")
        }
    }

    /// Where the capture tells what happened (the clips log), when the app set one.
    nonisolated(unsafe) static var log: (@Sendable (String) -> Void)?

    private func keepSound(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        let raw = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let audible = Self.hasSignal(sample)
        lock.lock()
        // Sound and pictures should share a clock; if they don't, sound is put on the pictures' clock as it
        // arrives (it is "now" for both), or the ring would drop it as older than every picture.
        if audioOffset == nil, let newest = ring.pieces.last(where: { $0.isVideo })?.time {
            audioOffset = abs(newest - raw) > 1 ? newest - raw : 0
            Self.log?("sound clock \(raw), picture clock \(newest): offset \(audioOffset!)")
        }
        let time = raw + (audioOffset ?? 0)
        if firstAudio == nil {
            firstAudio = time
            let format = CMSampleBufferGetFormatDescription(sample).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            Self.log?("sound arrives: \(format.map { "\(Int($0.mSampleRate)) Hz, \($0.mChannelsPerFrame) ch, \($0.mBitsPerChannel) bit, flags \($0.mFormatFlags)" } ?? "unknown format"), video at \(ring.duration.rounded()) s")
        }
        if audible, !heardSound { heardSound = true; Self.log?("sound heard") }
        if !stopped, audioOffset != nil {
            let piece = (audioOffset ?? 0) == 0 ? sample : Self.retimed(sample, by: audioOffset!) ?? sample
            ring.append(.init(time: time, isVideo: false, bytes: CMSampleBufferGetTotalSampleSize(sample), payload: piece))
        }
        lock.unlock()
    }

    /// The same sound, moved by `seconds` on the clock.
    static func retimed(_ sample: CMSampleBuffer, by seconds: Double) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        let shift = CMTime(seconds: seconds, preferredTimescale: 48_000)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, shift)
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, shift) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// Whether a block of sound is more than silence (all zeros is what a broken capture hands over).
    static func hasSignal(_ sample: CMSampleBuffer) -> Bool {
        var size = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil,
                                                                      bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: 0, blockBufferOut: nil) == noErr || size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        var block: CMBlockBuffer?
        let pointer = list.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: pointer, bufferListSize: size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return false }
        let description = CMSampleBufferGetFormatDescription(sample).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let isFloat = description.map { $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 } ?? true
        let bits = Int(description?.mBitsPerChannel ?? 32)
        for buffer in UnsafeMutableAudioBufferListPointer(pointer) {
            guard let data = buffer.mData else { continue }
            if isFloat, bits == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let floats = data.assumingMemoryBound(to: Float.self)
                for index in stride(from: 0, to: count, by: 8) where abs(floats[index]) > 0.0001 { return true }
            } else if bits == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let ints = data.assumingMemoryBound(to: Int16.self)
                for index in stride(from: 0, to: count, by: 8) where abs(Int(ints[index])) > 3 { return true }
            } else {
                // Any other layout: not silence if any byte is set.
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                for index in stride(from: 0, to: Int(buffer.mDataByteSize), by: 16) where bytes[index] != 0 { return true }
            }
        }
        return false
    }

    // MARK: The encoder

    private static func makeEncoder(size: CGSize, profile: ClipSettings.Quality.Profile) -> VTCompressionSession? {
        for codec in [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264] {
            var session: VTCompressionSession?
            let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            guard VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: codec,
                                             encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                             outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else { continue }
            func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
            set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
            set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
            set(kVTCompressionPropertyKey_ExpectedFrameRate, profile.fps as CFNumber)
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, profile.fps as CFNumber)                 // a key frame a second
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 as CFNumber)
            set(kVTCompressionPropertyKey_AverageBitRate, profile.bitsPerSecond as CFNumber)
            set(kVTCompressionPropertyKey_DataRateLimits, [profile.bitsPerSecond / 8 * 2, 1] as CFArray)
            set(kVTCompressionPropertyKey_ProfileLevel, codec == kCMVideoCodecType_HEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
            set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
            set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2)
            set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
            guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { VTCompressionSessionInvalidate(session); continue }
            return session
        }
        return nil
    }

    private func closeEncoder() {
        lock.lock()
        let session = encoder
        encoder = nil
        lock.unlock()
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: Writing a clip

    struct Snapshot: @unchecked Sendable {
        var pieces: [ReplayRing<CMSampleBuffer>.Piece]
        var size: CGSize
        var fps: Int
        var quality: ClipSettings.Quality
        var hasSound: Bool
        var seconds: Double
    }

    /// The last `seconds` of what is kept, copied out (cheap: the pieces are shared, not copied).
    func snapshot(last seconds: Double) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        let pieces = ring.clip(last: seconds)
        guard let first = pieces.first(where: { $0.isVideo }), let last = pieces.last(where: { $0.isVideo }) else { return nil }
        let sound = settings.gameSound && heardSound && pieces.contains { !$0.isVideo }
        return Snapshot(pieces: pieces, size: encoderSize, fps: settings.quality.profile.fps, quality: settings.quality, hasSound: sound,
                        seconds: last.time - first.time + 1.0 / Double(max(1, settings.quality.profile.fps)))
    }

    /// Writes the snapshot as an MP4: the video as it was compressed, the sound as AAC.
    static func write(_ snapshot: Snapshot, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let video = snapshot.pieces.filter { $0.isVideo }
        guard let first = video.first, let format = CMSampleBufferGetFormatDescription(first.payload) else { throw Failure.noVideo }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if snapshot.hasSound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }
        guard writer.startWriting() else { throw Failure.writerFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: first.payload.presentationTimeStamp)
        // Each track is fed as the writer asks for it. The writer keeps the tracks in step, so a track that ran
        // ahead is "not ready" until the other catches up: feeding them in turn, and finishing a track as soon as
        // it has nothing left, keeps it from waiting on sound that never comes.
        var queues: [(input: AVAssetWriterInput, pieces: ArraySlice<ReplayRing<CMSampleBuffer>.Piece>)] = [(videoInput, video[...])]
        if let audioInput {
            let sound = snapshot.pieces.filter { !$0.isVideo }
            if sound.isEmpty { audioInput.markAsFinished() } else { queues.append((audioInput, sound[...])) }
        }
        var idle = 0
        while queues.contains(where: { !$0.pieces.isEmpty }) {
            var progressed = false
            for index in queues.indices where !queues[index].pieces.isEmpty {
                let input = queues[index].input
                while input.isReadyForMoreMediaData, let piece = queues[index].pieces.first {
                    if !input.append(piece.payload) { throw Failure.writerFailed(writer.error?.localizedDescription ?? "append") }
                    queues[index].pieces.removeFirst()
                    progressed = true
                }
                if queues[index].pieces.isEmpty { input.markAsFinished() }
            }
            if writer.status == .failed { throw Failure.writerFailed(writer.error?.localizedDescription ?? "failed") }
            if !progressed {
                idle += 1
                if idle > 5000 { throw Failure.writerFailed("stalled") }
                try await Task.sleep(for: .milliseconds(2))
            } else { idle = 0 }
        }
        queues.forEach { $0.input.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writerFailed(writer.error?.localizedDescription ?? "finish") }
    }

    /// Writes the part of a saved clip between `start` and `end` seconds without compressing it again. The cut
    /// starts on a key frame (a second apart), so it can begin up to a second before `start`.
    static func trim(_ source: URL, from start: Double, to end: Double, into url: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(output); audioOut = output
        }
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let formats = try await videoTrack.load(.formatDescriptions)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if let audioTrack, let audioFormat = try await audioTrack.load(.formatDescriptions).first {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }
        guard reader.startReading(), writer.startWriting() else { throw Failure.writerFailed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "start") }
        var begun = false
        var origin = CMTime.zero
        while let sample = videoOut.copyNextSampleBuffer() {
            if !begun {
                // The first picture of the cut must be a key frame.
                let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?
                    .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                if notSync { continue }
                origin = sample.presentationTimeStamp
                writer.startSession(atSourceTime: origin)
                begun = true
            }
            while !videoIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            videoIn.append(sample)
        }
        guard begun else { writer.cancelWriting(); throw Failure.noVideo }
        if let audioOut, let audioIn {
            while let sample = audioOut.copyNextSampleBuffer() {
                if sample.presentationTimeStamp < origin { continue }
                while !audioIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                audioIn.append(sample)
            }
        }
        videoIn.markAsFinished(); audioIn?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw Failure.writerFailed(writer.error?.localizedDescription ?? "finish") }
    }
}
