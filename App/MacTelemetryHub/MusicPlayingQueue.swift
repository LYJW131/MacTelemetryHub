import Foundation

enum MusicPlayingQueue {
    private static let cache = Cache()

    static func read(
        currentTrackID: String?,
        currentTitle: String?,
        currentArtist: String? = nil,
        currentAlbum: String? = nil
    ) -> AppleMusicQueueSnapshot? {
        guard let parsed = cache.load(
            currentTrackID: currentTrackID,
            currentArtist: currentArtist,
            currentAlbum: currentAlbum
        ) else { return nil }
        let index = indexOf(trackID: currentTrackID, title: currentTitle, in: parsed.tracks)
        return AppleMusicQueueSnapshot(
            beta: true,
            source: parsed.source,
            index: index,
            tracks: parsed.tracks
        )
    }

    private static func indexOf(
        trackID: String?,
        title: String?,
        in tracks: [AppleMusicQueueTrack]
    ) -> Int? {
        if let trackID, let index = tracks.firstIndex(where: { $0.trackID == trackID }) {
            return index
        }
        // 资料库里同名曲常见，重名就不猜。
        if let title {
            let hits = tracks.indices.filter { tracks[$0].title == title }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Music/Music Library.musiclibrary/Preferences/Queue.dat")
    }

    private struct TrackMeta {
        var artist: String?
        var album: String?
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var mtime: TimeInterval?
        private var parsed: Parsed?
        private var library: [String: TrackMeta] = [:]

        func load(
            currentTrackID: String?,
            currentArtist: String?,
            currentAlbum: String?
        ) -> Parsed? {
            let url = MusicPlayingQueue.fileURL
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let stamp = values?.contentModificationDate?.timeIntervalSince1970

            lock.lock()
            let reuse = stamp != nil && stamp == mtime && parsed != nil
            var snapshot = parsed
            if let id = currentTrackID {
                library[id] = TrackMeta(
                    artist: currentArtist ?? library[id]?.artist,
                    album: currentAlbum ?? library[id]?.album
                )
            }
            lock.unlock()

            if !reuse {
                snapshot = Self.parse(url)
                lock.lock()
                mtime = stamp
                parsed = snapshot
                lock.unlock()
            }
            guard let snapshot else { return nil }

            let missing: [String] = {
                lock.lock()
                defer { lock.unlock() }
                return snapshot.tracks.compactMap { track in
                    guard let id = track.trackID else { return nil }
                    let meta = library[id]
                    return (meta?.artist == nil && meta?.album == nil) ? id : nil
                }
            }()
            if !missing.isEmpty, let fetched = Self.fetchLibraryMeta() {
                lock.lock()
                for (id, meta) in fetched {
                    library[id] = meta
                }
                lock.unlock()
            }

            lock.lock()
            let catalog = library
            lock.unlock()
            let tracks = snapshot.tracks.map { track -> AppleMusicQueueTrack in
                guard let id = track.trackID, let meta = catalog[id] else { return track }
                return AppleMusicQueueTrack(
                    title: track.title,
                    artist: meta.artist,
                    album: meta.album,
                    trackID: id
                )
            }
            let filled = Parsed(source: snapshot.source, tracks: tracks)
            lock.lock()
            parsed = filled
            lock.unlock()
            return filled
        }

        /// 一次 Apple Event 拉齐资料库，实测 730 首约 0.1s，比按 ID 逐首查快两个数量级。
        private static func fetchLibraryMeta() -> [String: TrackMeta]? {
            let source = """
            tell application "Music"
                if not (exists library playlist 1) then return {}
                set ids to persistent ID of every track of library playlist 1
                set arts to artist of every track of library playlist 1
                set albs to album of every track of library playlist 1
                return {ids, arts, albs}
            end tell
            """
            var errorInfo: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo) else {
                return nil
            }
            let ids = stringList(result.atIndex(1))
            let arts = stringList(result.atIndex(2))
            let albs = stringList(result.atIndex(3))
            let count = min(ids.count, arts.count, albs.count)
            guard count > 0 else { return nil }
            var map: [String: TrackMeta] = [:]
            map.reserveCapacity(count)
            for i in 0..<count {
                let id = ids[i].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else { continue }
                map[id] = TrackMeta(
                    artist: nonempty(arts[i]),
                    album: nonempty(albs[i])
                )
            }
            return map
        }

        private static func stringList(_ descriptor: NSAppleEventDescriptor?) -> [String] {
            guard let descriptor else { return [] }
            if descriptor.numberOfItems > 0 {
                return (1...descriptor.numberOfItems).map { descriptor.atIndex($0)?.stringValue ?? "" }
            }
            if let value = descriptor.stringValue { return [value] }
            return []
        }

        private static func parse(_ url: URL) -> Parsed? {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let root = dict(plist) else { return nil }

            var tracks: [AppleMusicQueueTrack] = []
            var source: String?
            for segment in array(root["sega"]) ?? [] {
                guard let segment = dict(segment) else { continue }
                if source == nil {
                    source = dict(segment["tlSrc"]).flatMap { string($0["name"]) }
                }
                let items = dict(segment["items"])
                    .flatMap { dict($0["list"]) }
                    .flatMap { dict($0["items"]) }
                    .flatMap { array($0["iar"]) } ?? []
                for item in items {
                    guard let item = dict(item),
                          let pm = dict(item["pm"]),
                          let title = string(pm["name"]), !title.isEmpty else { continue }
                    let spec = dict(pm["piObjSpec"])
                    tracks.append(
                        AppleMusicQueueTrack(
                            title: title,
                            artist: nil,
                            album: nil,
                            trackID: persistentID(spec?["tID"])
                        )
                    )
                }
            }
            guard !tracks.isEmpty else { return nil }
            return Parsed(source: source, tracks: tracks)
        }

        private static func nonempty(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
        private static func array(_ value: Any?) -> [Any]? { value as? [Any] }
        private static func string(_ value: Any?) -> String? { value as? String }

        /// Music.app AppleScript 的 persistent ID 是 16 位大写十六进制。
        private static func persistentID(_ value: Any?) -> String? {
            let raw: Int64?
            if let number = value as? Int64 {
                raw = number
            } else if let number = value as? Int {
                raw = Int64(number)
            } else if let number = value as? NSNumber {
                raw = number.int64Value
            } else {
                raw = nil
            }
            guard let raw else { return nil }
            return String(format: "%016llX", UInt64(bitPattern: raw))
        }
    }

    private struct Parsed {
        let source: String?
        let tracks: [AppleMusicQueueTrack]
    }
}
