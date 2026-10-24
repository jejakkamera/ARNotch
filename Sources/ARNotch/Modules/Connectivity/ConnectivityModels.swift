import Foundation
import CoreAudio

struct ConnectionBattery: Equatable, Sendable, Identifiable {
    let label: String
    let percent: Int
    var id: String { label }
}

struct ConnectedAudio: Identifiable, Equatable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let transport: String
    let hasOutput: Bool
    let hasInput: Bool
    let isDefault: Bool
    let volume: Double?
    let canSetVolume: Bool
    let isMuted: Bool?
    let canMute: Bool
    var batteries: [ConnectionBattery] = []
    var id: String { uid }
    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpodspro" }
        if lower.contains("head") || lower.contains("buds") || transport == "Bluetooth" { return "headphones" }
        return hasOutput ? "speaker.wave.2.fill" : "mic.fill"
    }
}

struct ConnectedDisplay: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let detail: String
    let isMirrored: Bool
    let isMain: Bool
}

struct ConnectedPeripheral: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let transport: String
    let symbol: String
    var batteries: [ConnectionBattery]
}

struct ConnectivitySnapshot: Equatable, Sendable {
    var audio: [ConnectedAudio] = []
    var peripherals: [ConnectedPeripheral] = []
}
