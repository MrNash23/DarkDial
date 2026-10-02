// A Darkdial without hardware, visible to macOS as a real MIDI device.
//
// Creates a virtual CoreMIDI source and destination named "Darkdial" and
// connects them to the firmware core built for the host (dd_sim). The desktop
// app then finds and uses it through its normal MIDI path, exactly as it
// would the device.
//
//     firmware/host/build.sh --core-only
//     swift tools/virtual_device.swift
//
// Type into its terminal:  C = press the knob,  R 3 / R -1 = turn,  ? = state.
// All MIDI traffic is printed.

import CoreMIDI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let simulator = root.appendingPathComponent("firmware/host/build/dd_sim")
guard FileManager.default.isExecutableFile(atPath: simulator.path) else {
  print("dd_sim is missing: run firmware/host/build.sh --core-only")
  exit(1)
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func bytes(fromHex text: String) -> [UInt8] {
  var result: [UInt8] = []
  var index = text.startIndex
  while let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) {
    if let byte = UInt8(text[index..<next], radix: 16) { result.append(byte) }
    index = next
  }
  return result
}

// The firmware core as a child process.
let process = Process()
process.executableURL = simulator
let toCore = Pipe()
let fromCore = Pipe()
process.standardInput = toCore
process.standardOutput = fromCore
try process.run()

let writeLock = NSLock()
func tellCore(_ line: String) {
  writeLock.lock()
  toCore.fileHandleForWriting.write((line + "\n").data(using: .utf8)!)
  writeLock.unlock()
}

var client = MIDIClientRef()
MIDIClientCreateWithBlock("Darkdial virtual device" as CFString, &client, nil)
var source = MIDIEndpointRef()
MIDISourceCreate(client, "Darkdial" as CFString, &source)

func sendToHost(_ message: [UInt8]) {
  var buffer = [UInt8](repeating: 0, count: 1024)
  buffer.withUnsafeMutableBytes { raw in
    let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
    let packet = MIDIPacketListInit(list)
    _ = MIDIPacketListAdd(list, 1024, packet, 0, message.count, message)
    MIDIReceived(source, list)
  }
}

// Host -> device. CoreMIDI may deliver a SysEx in pieces; collect F0 … F7.
var pending: [UInt8] = []
var destination = MIDIEndpointRef()
MIDIDestinationCreateWithBlock(client, "Darkdial" as CFString, &destination) { list, _ in
  var packet = UnsafeRawPointer(list).advanced(by: 4).assumingMemoryBound(to: MIDIPacket.self)
  for _ in 0..<list.pointee.numPackets {
    let length = Int(packet.pointee.length)
    let data = UnsafeRawPointer(packet).advanced(by: 10).assumingMemoryBound(to: UInt8.self)
    for byte in UnsafeBufferPointer(start: data, count: length) {
      if byte == 0xF0 { pending = [] }
      pending.append(byte)
      if byte == 0xF7 {
        print("host -> device  \(hex(pending))")
        tellCore("M \(hex(pending))")
        pending = []
      }
    }
    packet = UnsafePointer(MIDIPacketNext(packet))
  }
}

// Device -> host.
var partial = ""
fromCore.fileHandleForReading.readabilityHandler = { handle in
  guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
  partial += text
  while let newline = partial.firstIndex(of: "\n") {
    let line = String(partial[..<newline])
    partial = String(partial[partial.index(after: newline)...])
    if line.hasPrefix("M ") {
      let message = bytes(fromHex: String(line.dropFirst(2)))
      print("device -> host  \(hex(message))")
      sendToHost(message)
    } else {
      print("state           \(line)")
    }
  }
}

// The core has no clock of its own.
let clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in tellCore("T 100") }

// Knob input from the terminal.
FileHandle.standardInput.readabilityHandler = { handle in
  let data = handle.availableData
  if data.isEmpty {  // stdin closed
    process.terminate()
    exit(0)
  }
  for line in String(data: data, encoding: .utf8)!.split(separator: "\n") {
    tellCore(String(line))
  }
}

print("Virtual MIDI device \"Darkdial\" is up. C = press, R <n> = turn, ? = state, Ctrl-D = quit.")
RunLoop.main.run()
_ = clock
