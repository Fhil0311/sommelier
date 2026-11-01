// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

/// The sound some processes play, taken straight from Core Audio (a process tap, macOS 14.4+): what the game
/// sends to the speakers, nothing else, whatever device it plays through. Each block of sound comes as a
/// sample buffer stamped on the host clock, the same clock ScreenCaptureKit stamps pictures with.
final class ProcessAudioTap: @unchecked Sendable {
    enum Failure: Error { case noProcess, tapFailed(OSStatus), deviceFailed(OSStatus), noFormat, startFailed(OSStatus) }

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var format: CMAudioFormatDescription?
    private var running = false
    private let queue = DispatchQueue(label: "gg.sommelier.clips.tap", qos: .userInitiated)

    /// What each process's object id is in Core Audio; processes it doesn't know (no sound ever) are left out.
    static func audioObjects(of pids: [pid_t]) -> [AudioObjectID] {
        pids.compactMap { pid in
            var pid = pid
            var object = AudioObjectID(kAudioObjectUnknown)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = withUnsafeMutablePointer(to: &pid) { qualifier in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), qualifier, &size, &object)
            }
            return status == noErr && object != kAudioObjectUnknown ? object : nil
        }
    }

    /// The UID of the device sound goes to now.
    static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }

    /// Starts taking the sound of `pids`; `deliver` gets each block (on a private queue).
    func start(pids: [pid_t], deliver: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        let objects = Self.audioObjects(of: pids)
        guard !objects.isEmpty else { throw Failure.noProcess }
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.name = "Sommelier clips"
        description.isPrivate = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.tapFailed(status) }
        tap = tapID

        // The tap plays into a private aggregate device of its own, built on the Mac's output device (the tap
        // alone gives no clock to run on), which is what an IO proc can be put on.
        guard let output = Self.defaultOutputUID() else { stop(); throw Failure.deviceFailed(-1) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sommelier clips",
            kAudioAggregateDeviceUIDKey: "gg.sommelier.clips.\(description.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { stop(); throw Failure.deviceFailed(status) }
        device = deviceID

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &streamDescription) == noErr else { stop(); throw Failure.noFormat }
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { stop(); throw Failure.noFormat }
        format = formatDescription
        let bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        let rate = Int32(streamDescription.mSampleRate)

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, inData, inTime, _, _ in
            // Each block: the samples copied into a sample buffer stamped when they were played.
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let first = list.first, let data = first.mData, first.mDataByteSize > 0, bytesPerFrame > 0 else { return }
            let frames = Int(first.mDataByteSize) / bytesPerFrame
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: Int(first.mDataByteSize), blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: Int(first.mDataByteSize), flags: 0,
                                                     blockBufferOut: &block) == noErr, let block,
                  CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: Int(first.mDataByteSize)) == noErr
            else { return }
            let time = inTime.pointee.mFlags.contains(.hostTimeValid)
                ? CMClockMakeHostTimeFromSystemUnits(inTime.pointee.mHostTime) : CMClockGetTime(CMClockGetHostTimeClock())
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                       formatDescription: formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
                                       sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: [bytesPerFrame],
                                       sampleBufferOut: &sample) == noErr, let sample else { return }
            deliver(sample)
        }
        guard status == noErr, let proc else { stop(); throw Failure.startFailed(status) }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { stop(); throw Failure.startFailed(status) }
        running = true
    }

    /// "48000 Hz, 2 ch, 32 bit": what the tap hands over.
    var formatText: String {
        guard let format, let d = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return "unknown" }
        return "\(Int(d.mSampleRate)) Hz, \(d.mChannelsPerFrame) ch, \(d.mBitsPerChannel) bit, flags \(d.mFormatFlags)"
    }

    func stop() {
        if running, let procID { AudioDeviceStop(device, procID); running = false }
        if let procID { AudioDeviceDestroyIOProcID(device, procID); self.procID = nil }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
    }

    deinit { stop() }
}
