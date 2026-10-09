import Foundation
import CoreMIDI
import PiezoCore

struct MIDIStatus {
    var available = false
    var sent: UInt64 = 0
    var lastMessage = "No drum hits yet"
    var error: String?
}

final class MIDIOutput {
    private let queue = DispatchQueue(label: "com.dustmason.piezo.midi", qos: .userInteractive)
    private var client = MIDIClientRef(), source = MIDIEndpointRef()
    private var enabled = false
    private var active: [Int: UInt64] = [:]
    private var generation: UInt64 = 0
    private var status = MIDIStatus()
    var onStatus: ((MIDIStatus) -> Void)?

    func configure(enabled: Bool) {
        queue.async { [self] in
            if self.source == 0 {
                var result = MIDIClientCreateWithBlock("Piezo Box" as CFString, &self.client, nil)
                if result == noErr {
                    result = MIDISourceCreateWithProtocol(self.client, "Piezo Box Drums" as CFString, ._1_0, &self.source)
                }
                if result != noErr { self.status.error = "Cannot create MIDI source (\(result))." }
                else {
                    _ = MIDIObjectSetIntegerProperty(self.source, kMIDIPropertyUniqueID, 0x50695A6F)
                    self.status.available = true; self.status.error = nil
                }
            }
            if !enabled { self.silence() }
            self.enabled = enabled
            self.onStatus?(self.status)
        }
    }
    func hit(_ hit: DrumHit, channel: Int, test: Bool = false) {
        queue.async { [self] in
            guard self.enabled, self.source != 0 else { return }
            let ch = min(15, max(0, channel - 1)), note = min(127, max(0, hit.note))
            let key = ch * 128 + note
            if self.active[key] != nil { self.send(status: 0x80 | ch, note: note, velocity: 0) }
            self.send(status: 0x90 | ch, note: note, velocity: hit.velocity)
            self.generation += 1; let token = self.generation; self.active[key] = token
            self.status.sent += 1
            self.status.lastMessage = "\(test ? "Test" : "Input \(hit.input + 1)") · note \(note) · velocity \(hit.velocity)"
            self.onStatus?(self.status)
            self.queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.active[key] == token else { return }
                self.send(status: 0x80 | ch, note: note, velocity: 0); self.active.removeValue(forKey: key)
            }
        }
    }
    func allNotesOff() { queue.async { self.silence() } }
    func shutdown() {
        queue.sync {
            silence()
            if source != 0 { MIDIEndpointDispose(source); source = 0 }
            if client != 0 { MIDIClientDispose(client); client = 0 }
        }
    }
    private func silence() {
        for key in active.keys { send(status: 0x80 | (key / 128), note: key % 128, velocity: 0) }
        active.removeAll(); generation += 1
    }
    private func send(status: Int, note: Int, velocity: Int) {
        var list = MIDIEventList()
        var word = UInt32(0x20000000) | UInt32(status) << 16 | UInt32(note) << 8 | UInt32(max(0, min(127, velocity)))
        withUnsafeMutablePointer(to: &list) { pointer in
            let packet = MIDIEventListInit(pointer, ._1_0)
            _ = MIDIEventListAdd(pointer, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
            let result = MIDIReceivedEventList(source, pointer)
            if result != noErr { self.status.error = "MIDI send failed (\(result))." }
        }
    }
}
