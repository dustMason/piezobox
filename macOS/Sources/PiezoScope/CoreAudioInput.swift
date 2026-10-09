import Foundation
import CoreAudio
import AVFoundation
import PiezoAudioBridge

struct AudioInputDevice: Identifiable, Equatable {
    let objectID: AudioDeviceID
    let uid: String
    let title: String
    var id: String { uid }
}
enum AudioInputDiscovery {
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let result = value?.takeRetainedValue() else { return "" }
        return result as String
    }
    static func devices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let uid = string(id, kAudioDevicePropertyDeviceUID), name = string(id, kAudioObjectPropertyName)
            guard uid.contains(":Piezo Box LC:"), name.contains("7 Inputs") else { return nil }
            return AudioInputDevice(objectID: id, uid: uid, title: name)
        }.sorted { $0.uid < $1.uid }
    }
}
struct PCMInputBlock {
    let samples: [Float]
    let frames: Int
    let dropped: UInt64
    let discontinuities: UInt64
}
enum AudioInputEvent {
    case message(String), live(bufferFrames: Int), block(PCMInputBlock), finished(String?)
}

/// A C callback copies PCM to an SPSC ring. Swift drains it off the audio thread;
/// trigger detection, CoreMIDI, allocations, and UI updates never block that callback.
final class CoreAudioInput {
    private let queue = DispatchQueue(label: "com.dustmason.piezo.input", qos: .userInteractive)
    private var capture: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var handler: ((AudioInputEvent) -> Void)?
    private var lastData: TimeInterval = 0
    private var generation = 0
    func start(_ device: AudioInputDevice, handler: @escaping (AudioInputEvent) -> Void) {
        queue.async {
            self.stopOnQueue(notify: false)
            self.generation += 1; let generation = self.generation
            self.handler = handler
            handler(.message("Opening USB audio input…"))
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    self.queue.async {
                        guard self.generation == generation else { return }
                        if allowed { self.open(device) } else { self.fail("Allow microphone access for Piezo Scope in System Settings to read this audio input.") }
                    }
                }
            } else if status == .denied || status == .restricted {
                self.fail("Allow microphone access for Piezo Scope in System Settings to read this audio input.")
            } else { self.open(device) }
        }
    }
    private func open(_ device: AudioInputDevice) {
        var error: Int32 = 0
        guard let capture = pz_capture_open(device.objectID, 7, &error) else {
            fail("Cannot open the seven-channel USB input (\(error)). Reconnect the Teensy and try again."); return
        }
        self.capture = capture; lastData = ProcessInfo.processInfo.systemUptime
        handler?(.live(bufferFrames: Int(pz_capture_buffer_frames(capture))))
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(250))
        source.setEventHandler { [weak self] in self?.drain() }; timer = source; source.resume()
    }
    private func drain() {
        guard let capture else { return }
        var samples = [Float](repeating: 0, count: 1024 * 7)
        let frames = samples.withUnsafeMutableBufferPointer { Int(pz_capture_read(capture, $0.baseAddress, 1024)) }
        if frames > 0 {
            lastData = ProcessInfo.processInfo.systemUptime
            samples.removeLast(samples.count - frames * 7)
            handler?(.block(PCMInputBlock(samples: samples, frames: frames, dropped: pz_capture_dropped(capture), discontinuities: pz_capture_discontinuities(capture))))
        } else if ProcessInfo.processInfo.systemUptime - lastData > 2.5 { fail("The USB audio input stopped. Reconnect the Teensy and press Start.") }
    }
    func stop() { queue.async { self.generation += 1; self.stopOnQueue(notify: true) } }
    func shutdown() { queue.sync { generation += 1; stopOnQueue(notify: false) } }
    private func stopOnQueue(notify: Bool) {
        timer?.cancel(); timer = nil
        if let capture { pz_capture_close(capture); self.capture = nil }
        if notify { handler?(.finished(nil)) }
        handler = nil
    }
    private func fail(_ message: String) { let callback = handler; stopOnQueue(notify: false); callback?(.finished(message)) }
}
