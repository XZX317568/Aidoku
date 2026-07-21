//
//  Download.swift
//  Aidoku
//
//  Created by Skitty on 5/14/22.
//

import AidokuRunner
import Foundation

enum DownloadStatus: Int, Codable {
    case none = 0
    case queued
    case downloading
    case paused
    case cancelled
    case finished
    case failed
}

struct Download: Equatable, Sendable, Codable {
    var mangaIdentifier: MangaIdentifier { chapterIdentifier.mangaIdentifier }
    let chapterIdentifier: ChapterIdentifier

    var status: DownloadStatus = .queued

    var progress: Int = 0
    var total: Int = 0

    /// Download speed in bytes per second (transient, not persisted)
    var speed: Double = 0
    /// Estimated seconds remaining (transient, not persisted)
    var estimatedTimeRemaining: TimeInterval?

    var manga: AidokuRunner.Manga
    var chapter: AidokuRunner.Chapter

    enum CodingKeys: String, CodingKey {
        case chapterIdentifier, status, progress, total, manga, chapter
    }

    static func == (lhs: Download, rhs: Download) -> Bool {
        lhs.chapterIdentifier == rhs.chapterIdentifier
    }

    static func from(
        manga: AidokuRunner.Manga,
        chapter: AidokuRunner.Chapter,
        status: DownloadStatus = .queued
    ) -> Download {
        Download(
            chapterIdentifier: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key),
            status: status,
            manga: manga,
            chapter: chapter
        )
    }
}

extension Download: Identifiable {
    var id: ChapterIdentifier { chapterIdentifier }
}
