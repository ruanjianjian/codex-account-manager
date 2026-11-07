import Foundation

/// The gateway as a launchd agent: launchd keeps it running whether Tibot runs, quits, updates or crashes, so
/// Codex never points at a port nobody serves. It runs a copy of the binary kept next to the pool, so moving or
/// replacing Tibot.app never breaks it.
public struct GatewayAgent: Equatable {
    public let label: String
    /// The gateway folder: pool.json, the binary copy, the diagnostics log.
    public let directory: URL
    public let port: Int
    public let desktopAuth: URL
    public let bundleID: String
    public let launchAgents: URL
    public init(bundleID: String, directory: URL, port: Int, desktopAuth: URL, launchAgents: URL) {
        self.label = bundleID + ".gateway"; self.bundleID = bundleID
        self.directory = directory; self.port = port; self.desktopAuth = desktopAuth; self.launchAgents = launchAgents
    }
    public var binary: URL { directory.appendingPathComponent("AccountsGateway") }
    public var pool: URL { directory.appendingPathComponent("pool.json") }
    public var plistURL: URL { launchAgents.appendingPathComponent(label + ".plist") }
    public var arguments: [String] {
        [binary.path, "--config", pool.path, "--listen", "127.0.0.1:\(port)", "--desktop-auth", desktopAuth.path]
    }
    public func plist() throws -> Data {
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            // Codex waits on every request it serves.
            "ProcessType": "Interactive",
            "ThrottleInterval": 3,
            // System Settings → Login Items lists it under Tibot.
            "AssociatedBundleIdentifiers": [bundleID],
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }
    /// The old way, before 0.4.29: a gateway Tibot started as its child, from inside its own bundle, on this port.
    /// Another build's gateway (its own port) is never matched.
    public var childPattern: String { "Contents/Helpers/AccountsGateway --config .* --listen 127\\.0\\.0\\.1:\(port)( |$)" }
}

extension GatewayActivityEvent {
    /// One line of the gateway's event stream (GET /tibot/events): `data: {json}`; pings and blank lines are nil.
    public static func streamLine(_ line: String) -> GatewayActivityEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        return try? JSONDecoder().decode(GatewayActivityEvent.self, from: Data(line.dropFirst(6).utf8))
    }
}
