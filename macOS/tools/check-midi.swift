import Foundation
import CoreMIDI
import Darwin
var client = MIDIClientRef(), port = MIDIPortRef()
guard MIDIClientCreateWithBlock("Piezo verification" as CFString, &client, nil) == noErr else { fatalError("MIDI client failed") }
let result = MIDIInputPortCreateWithProtocol(client, "Verification input" as CFString, ._1_0, &port) { list, _ in
    var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIEventPacket.self)
    for _ in 0..<list.pointee.numPackets {
        let p = packet.pointee
        withUnsafeBytes(of: p.words) { bytes in
            for i in 0..<Int(p.wordCount) {
                let word = bytes.load(fromByteOffset: i * 4, as: UInt32.self)
                print(String(format: "MIDI %08x", word)); fflush(stdout)
            }
        }
        packet = UnsafePointer(MIDIEventPacketNext(packet))
    }
}
guard result == noErr else { fatalError("MIDI port failed: \(result)") }
var connected = false
for i in 0..<MIDIGetNumberOfSources() {
    let endpoint = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) == noErr,
       let value = name?.takeRetainedValue(), value as String == "Piezo Box Drums" {
        guard MIDIPortConnectSource(port, endpoint, nil) == noErr else { fatalError("Connect failed") }
        connected = true; print("Connected to Piezo Box Drums"); fflush(stdout)
    }
}
guard connected else { fatalError("Piezo MIDI source missing") }
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60))
MIDIPortDispose(port); MIDIClientDispose(client)
