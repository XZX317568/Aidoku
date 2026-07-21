//
//  Backup.swift
//  Aidoku
//
//  Created by Skitty on 2/26/22.
//

import Foundation

struct Backup: Codable, Hashable, Identifiable, Sendable {
    var id: Int { hashValue }

    var library: [BackupLibraryManga]?
    var history: [BackupHistory]?
    var manga: [BackupManga]?
    var chapters: [BackupChapter]?
    var trackItems: [BackupTrackItem]?
    var readingSessions: [BackupReadingSession]?
    var updates: [BackupUpdate]?
    var categories: [BackupCategory]?
    var sources: [BackupSource]?
    var sourceLists: [String]?
    var settings: [String: JsonAnyValue]?
    var date: Date
    var name: String?
    var automatic: Bool?
    var version: String?

    static func load(from url: URL) -> Backup? {
        guard var data = try? Data(contentsOf: url) else { return nil }

        // Try decoding directly first (uncompressed backups)
        if let backup = try? PropertyListDecoder().decode(Backup.self, from: data) {
            return backup
        }

        // Try decompressing zlib-compressed backups
        if let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data? {
            data = decompressed
            if let backup = try? PropertyListDecoder().decode(Backup.self, from: data) {
                return backup
            }
        }

        // Fallback: try JSON decoding (legacy format)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Backup.self, from: data)
    }
}
