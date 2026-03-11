//
//  CookSessionStore.swift
//  CombAnalyser
//

import Foundation

class CookSessionStore: ObservableObject {
    static let shared = CookSessionStore()

    @Published private(set) var sessions: [PersistedCookSession] = []

    private let sessionsDirectory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDirectory = appSupport.appendingPathComponent("CombAnalyser/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        loadAll()
    }

    func save(_ session: PersistedCookSession) {
        let fileURL = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: fileURL, options: .atomic)

        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
            sessions.sort { $0.startDate > $1.startDate }
        }
    }

    func delete(_ session: PersistedCookSession) {
        let fileURL = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
        sessions.removeAll { $0.id == session.id }
    }

    func session(forProbeSerial serial: String, sdkSessionID: UInt32?) -> PersistedCookSession? {
        if let sdkID = sdkSessionID {
            return sessions.first { $0.probeSerial == serial && $0.sdkSessionID == sdkID }
        }
        return nil
    }

    func mostRecentSession(forProbeSerial serial: String) -> PersistedCookSession? {
        sessions.first { $0.probeSerial == serial }
    }

    private func loadAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else { return }

        sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> PersistedCookSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(PersistedCookSession.self, from: data)
            }
            .sorted { $0.startDate > $1.startDate }
    }
}
