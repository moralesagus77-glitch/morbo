import Foundation

struct AudioSource {
    let url: URL
    let headers: [String: String]
    let label: String
}

enum BackendError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum SourceMode: String {
    case auto
    case direct
    case community
}

/// Utilidades para recorrer JSON dinámico (las respuestas de YouTube cambian de forma seguido).
enum J {
    static func dict(_ v: Any?) -> [String: Any]? { return v as? [String: Any] }
    static func str(_ v: Any?) -> String? { return v as? String }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// Une el texto de todos los "runs" de un campo ({"runs":[{"text":"..."}]}).
    static func runsText(_ v: Any?) -> String {
        guard let d = v as? [String: Any], let runs = d["runs"] as? [[String: Any]] else { return "" }
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    /// Junta, en orden, los diccionarios que cuelgan de la clave `key` en cualquier nivel.
    static func collect(_ node: Any, key: String, into out: inout [[String: Any]]) {
        if let d = node as? [String: Any] {
            for k in d.keys.sorted() {
                guard let v = d[k] else { continue }
                if k == key, let r = v as? [String: Any] {
                    out.append(r)
                } else {
                    collect(v, key: key, into: &out)
                }
            }
        } else if let a = node as? [Any] {
            for v in a { collect(v, key: key, into: &out) }
        }
    }

    static func firstString(_ node: Any, key: String) -> String? {
        if let d = node as? [String: Any] {
            if let s = d[key] as? String { return s }
            for k in d.keys.sorted() {
                if let v = d[k], let s = firstString(v, key: key) { return s }
            }
        } else if let a = node as? [Any] {
            for v in a {
                if let s = firstString(v, key: key) { return s }
            }
        }
        return nil
    }
}

/// Todo lo que habla con YouTube: búsqueda, radio y obtención del audio.
/// Usa el mismo método que YTMLegacy: YouTube directo y, si falla, instancias de Piped / Invidious.
final class Backend {
    static let shared = Backend()

    static let defaultPiped = [
        "https://api.piped.private.coffee",
        "https://pipedapi.kavin.rocks",
        "https://pipedapi.adminforge.de"
    ]
    static let defaultInvidious = [
        "https://invidious.nerdvpn.de",
        "https://inv.nadeko.net",
        "https://invidious.f5.si",
        "https://yt.chocolatemoo53.com",
        "https://invidious.tiekoetter.com",
        "https://inv.zoomerville.com"
    ]

    private struct ClientConfig {
        let name: String
        let id: String
        let version: String
        let userAgent: String
        let fields: [String: Any]
    }

    private static let androidVR = ClientConfig(
        name: "ANDROID_VR",
        id: "28",
        version: "1.65.10",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        fields: [
            "deviceMake": "Oculus",
            "deviceModel": "Quest 3",
            "androidSdkVersion": 32,
            "osName": "Android",
            "osVersion": "12L"
        ]
    )

    private static let visionOS = ClientConfig(
        name: "VISIONOS",
        id: "101",
        version: "1.02",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        fields: [
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471"
        ]
    )

    private let session: URLSession
    private var visitorData: String?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 30
        session = URLSession(configuration: cfg)
    }

    // MARK: - Ajustes

    private var mode: SourceMode {
        let raw = UserDefaults.standard.string(forKey: "sourceMode") ?? "auto"
        return SourceMode(rawValue: raw) ?? .auto
    }

    private func custom(_ key: String) -> String {
        var t = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if !t.isEmpty && !t.lowercased().hasPrefix("http") { t = "https://" + t }
        return t
    }

    private var pipedList: [String] {
        let c = custom("customPiped")
        return (c.isEmpty ? [] : [c]) + Backend.defaultPiped
    }

    private var invidiousList: [String] {
        let c = custom("customInvidious")
        return (c.isEmpty ? [] : [c]) + Backend.defaultInvidious
    }

    private func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func host(_ base: String) -> String {
        return URL(string: base)?.host ?? base
    }

    // MARK: - HTTP

    private func postJSON(_ urlString: String, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw BackendError.message("URL inválida") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BackendError.message("HTTP \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackendError.message("respuesta inesperada")
        }
        return obj
    }

    private func getJSON(_ urlString: String) async throws -> Any {
        guard let url = URL(string: urlString) else { throw BackendError.message("URL inválida") }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BackendError.message("HTTP \(http.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - YouTube Music (búsqueda y radio)

    private func remixConfig() -> (context: [String: Any], headers: [String: String]) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        let version = "1.\(f.string(from: Date())).01.00"
        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": version,
            "hl": "en"
        ]
        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            "Origin": "https://music.youtube.com",
            "Referer": "https://music.youtube.com/",
            "X-YouTube-Client-Name": "67",
            "X-YouTube-Client-Version": version
        ]
        if let v = visitorData {
            client["visitorData"] = v
            headers["X-Goog-Visitor-Id"] = v
        }
        return (["client": client], headers)
    }

    private func ytm(_ endpoint: String, _ body: [String: Any]) async throws -> [String: Any] {
        let cfg = remixConfig()
        var b = body
        b["context"] = cfg.context
        let url = "https://music.youtube.com/youtubei/v1/\(endpoint)?alt=json&prettyPrint=false"
        let json = try await postJSON(url, body: b, headers: cfg.headers)
        if let rc = J.dict(json["responseContext"]), let vd = J.str(rc["visitorData"]) { visitorData = vd }
        return json
    }

    func search(_ query: String) async throws -> [Track] {
        var problems: [String] = []

        if mode != .community {
            do {
                let json = try await ytm("search", ["query": query, "params": "EgWKAQIIAWoMEA4QChADEAQQCRAF"])
                let tracks = parseSongs(json)
                AppLog.shared.add("[buscar] YouTube Music: \(tracks.count) resultados")
                if !tracks.isEmpty { return tracks }
                problems.append("YouTube Music sin resultados")
            } catch {
                AppLog.shared.add("[buscar] YouTube Music falló: \(error.localizedDescription)")
                problems.append("YouTube Music: \(error.localizedDescription)")
            }
            if mode == .direct {
                throw BackendError.message(problems.joined(separator: " | "))
            }
        }

        for base in pipedList.prefix(3) {
            do {
                let tracks = try await pipedSearch(base, query)
                AppLog.shared.add("[buscar] Piped \(host(base)): \(tracks.count) resultados")
                if !tracks.isEmpty { return tracks }
            } catch {
                AppLog.shared.add("[buscar] Piped \(host(base)) falló: \(error.localizedDescription)")
                problems.append("Piped \(host(base))")
            }
        }

        for base in invidiousList.prefix(3) {
            do {
                let tracks = try await invidiousSearch(base, query)
                AppLog.shared.add("[buscar] Invidious \(host(base)): \(tracks.count) resultados")
                if !tracks.isEmpty { return tracks }
            } catch {
                AppLog.shared.add("[buscar] Invidious \(host(base)) falló: \(error.localizedDescription)")
                problems.append("Invidious \(host(base))")
            }
        }

        throw BackendError.message("No se pudo buscar (" + problems.joined(separator: ", ") + ")")
    }

    private func parseSongs(_ json: [String: Any]) -> [Track] {
        var items: [[String: Any]] = []
        J.collect(json, key: "musicResponsiveListItemRenderer", into: &items)
        var out: [Track] = []
        var seen = Set<String>()
        for r in items {
            guard let t = parseListItem(r), !seen.contains(t.id) else { continue }
            seen.insert(t.id)
            out.append(t)
        }
        return out
    }

    private func parseListItem(_ r: [String: Any]) -> Track? {
        var videoId = J.str(J.dict(r["playlistItemData"])?["videoId"])
        if videoId == nil, let overlay = r["overlay"] {
            videoId = J.firstString(overlay, key: "videoId")
        }
        guard let id = videoId, !id.isEmpty else { return nil }

        let columns = (r["flexColumns"] as? [Any]) ?? []
        func runs(_ i: Int) -> [[String: Any]] {
            guard i < columns.count,
                  let col = J.dict(columns[i]),
                  let renderer = J.dict(col["musicResponsiveListItemFlexColumnRenderer"]),
                  let text = J.dict(renderer["text"]),
                  let list = text["runs"] as? [[String: Any]] else { return [] }
            return list
        }

        let title = runs(0).compactMap { J.str($0["text"]) }.joined()
        if title.isEmpty { return nil }

        // Segunda columna: "Artista • Álbum • 3:45" (a veces con "Song" o "Video" adelante).
        var parts: [String] = []
        var piece = ""
        for run in runs(1) {
            let text = J.str(run["text"]) ?? ""
            if text.trimmingCharacters(in: .whitespaces) == "•" {
                parts.append(piece)
                piece = ""
            } else {
                piece += text
            }
        }
        parts.append(piece)
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var duration: Double?
        if let last = parts.last, let d = Fmt.parseTime(last) {
            duration = d
            parts.removeLast()
        }
        let labels: Set<String> = ["song", "video", "canción", "vídeo"]
        parts = parts.filter { !labels.contains($0.lowercased()) }
        let artist = parts.first ?? ""

        var thumbnail: URL?
        if let tr = J.dict(r["thumbnail"]),
           let mt = J.dict(tr["musicThumbnailRenderer"]),
           let th = J.dict(mt["thumbnail"]),
           let list = th["thumbnails"] as? [[String: Any]],
           let u = J.str(list.last?["url"]) {
            thumbnail = URL(string: u)
        }
        return Track(id: id, title: title, artist: artist, duration: duration, thumbnail: thumbnail)
    }

    private func pipedSearch(_ base: String, _ query: String) async throws -> [Track] {
        let any = try await getJSON("\(base)/search?q=\(enc(query))&filter=music_songs")
        guard let root = any as? [String: Any], let items = root["items"] as? [[String: Any]] else {
            throw BackendError.message("respuesta inesperada")
        }
        var out: [Track] = []
        for item in items {
            guard J.str(item["type"]) == "stream",
                  let path = J.str(item["url"]),
                  let range = path.range(of: "v=") else { continue }
            let id = String(path[range.upperBound...]).components(separatedBy: "&")[0]
            if id.isEmpty { continue }
            let title = J.str(item["title"]) ?? ""
            let artist = (J.str(item["uploaderName"]) ?? "").replacingOccurrences(of: " - Topic", with: "")
            var thumbnail: URL?
            if let t = J.str(item["thumbnail"]) { thumbnail = URL(string: t) }
            var duration: Double?
            if let d = J.int(item["duration"]), d > 0 { duration = Double(d) }
            out.append(Track(id: id, title: title, artist: artist, duration: duration, thumbnail: thumbnail))
        }
        return out
    }

    private func invidiousSearch(_ base: String, _ query: String) async throws -> [Track] {
        let any = try await getJSON("\(base)/api/v1/search?q=\(enc(query))&type=video")
        guard let items = any as? [[String: Any]] else {
            throw BackendError.message("respuesta inesperada")
        }
        var out: [Track] = []
        for item in items {
            guard J.str(item["type"]) == "video", let id = J.str(item["videoId"]) else { continue }
            let title = J.str(item["title"]) ?? ""
            let artist = (J.str(item["author"]) ?? "").replacingOccurrences(of: " - Topic", with: "")
            var duration: Double?
            if let d = J.int(item["lengthSeconds"]), d > 0 { duration = Double(d) }
            out.append(Track(id: id, title: title, artist: artist, duration: duration, thumbnail: nil))
        }
        return out
    }

    /// Canciones parecidas (la "radio" de YouTube Music) a partir de una canción.
    func radio(for videoId: String) async -> [Track] {
        do {
            let json = try await ytm("next", [
                "videoId": videoId,
                "playlistId": "RDAMVM" + videoId,
                "isAudioOnly": true,
                "tunerSettingValue": "AUTOMIX_SETTING_NORMAL",
                "enablePersistentPlaylistPanel": true
            ])
            var items: [[String: Any]] = []
            J.collect(json, key: "playlistPanelVideoRenderer", into: &items)
            var out: [Track] = []
            var seen = Set<String>([videoId])
            for r in items {
                guard let id = J.str(r["videoId"]), !seen.contains(id) else { continue }
                let title = J.runsText(r["title"])
                if title.isEmpty { continue }
                seen.insert(id)
                var artist = J.runsText(r["shortBylineText"])
                if artist.isEmpty {
                    artist = J.runsText(r["longBylineText"]).components(separatedBy: " • ").first ?? ""
                }
                let duration = Fmt.parseTime(J.runsText(r["lengthText"]))
                var thumbnail: URL?
                if let th = J.dict(r["thumbnail"]),
                   let list = th["thumbnails"] as? [[String: Any]],
                   let u = J.str(list.last?["url"]) {
                    thumbnail = URL(string: u)
                }
                out.append(Track(id: id, title: title, artist: artist, duration: duration, thumbnail: thumbnail))
            }
            AppLog.shared.add("[radio] \(out.count) canciones parecidas")
            return out
        } catch {
            AppLog.shared.add("[radio] falló: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Audio

    func resolveAudio(for track: Track) async throws -> AudioSource {
        var problems: [String] = []

        if mode != .community {
            for client in [Backend.androidVR, Backend.visionOS] {
                do {
                    let src = try await innertubeAudio(videoId: track.id, client: client)
                    if await probe(src) {
                        AppLog.shared.add("[audio] \(track.title): OK (\(src.label))")
                        return src
                    }
                    problems.append("\(client.name): la URL no responde")
                } catch {
                    problems.append("\(client.name): \(error.localizedDescription)")
                }
                AppLog.shared.add("[audio] " + (problems.last ?? ""))
            }
            if mode == .direct {
                throw BackendError.message(problems.joined(separator: " | "))
            }
        }

        for base in pipedList.prefix(3) {
            do {
                let src = try await pipedAudio(base, track.id)
                if await probe(src) {
                    AppLog.shared.add("[audio] \(track.title): OK (\(src.label))")
                    return src
                }
                problems.append("Piped \(host(base)): la URL no responde")
            } catch {
                problems.append("Piped \(host(base)): \(error.localizedDescription)")
            }
            AppLog.shared.add("[audio] " + (problems.last ?? ""))
        }

        for base in invidiousList.prefix(3) {
            guard let url = URL(string: "\(base)/latest_version?id=\(track.id)&itag=140&local=true") else { continue }
            let src = AudioSource(url: url, headers: [:], label: "Invidious \(host(base))")
            if await probe(src) {
                AppLog.shared.add("[audio] \(track.title): OK (\(src.label))")
                return src
            }
            problems.append("Invidious \(host(base)): la URL no responde")
            AppLog.shared.add("[audio] " + (problems.last ?? ""))
        }

        throw BackendError.message("No encontré cómo reproducirla. " + (problems.last ?? ""))
    }

    private func innertubeAudio(videoId: String, client c: ClientConfig) async throws -> AudioSource {
        var clientInfo: [String: Any] = c.fields
        clientInfo["clientName"] = c.name
        clientInfo["clientVersion"] = c.version
        clientInfo["userAgent"] = c.userAgent
        clientInfo["hl"] = "en"
        if let v = visitorData { clientInfo["visitorData"] = v }

        let body: [String: Any] = [
            "context": ["client": clientInfo],
            "videoId": videoId,
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        var headers: [String: String] = [
            "User-Agent": c.userAgent,
            "X-YouTube-Client-Name": c.id,
            "X-YouTube-Client-Version": c.version,
            "Origin": "https://www.youtube.com"
        ]
        if let v = visitorData { headers["X-Goog-Visitor-Id"] = v }

        let json = try await postJSON("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", body: body, headers: headers)
        if visitorData == nil, let rc = J.dict(json["responseContext"]), let vd = J.str(rc["visitorData"]) {
            visitorData = vd
        }
        if let ps = J.dict(json["playabilityStatus"]), let status = J.str(ps["status"]), status != "OK" {
            throw BackendError.message("YouTube dice: " + (J.str(ps["reason"]) ?? status))
        }
        guard let streaming = J.dict(json["streamingData"]) else {
            throw BackendError.message("sin streamingData")
        }

        let adaptive = (streaming["adaptiveFormats"] as? [[String: Any]]) ?? []
        var audio = adaptive.filter { f in
            (J.str(f["mimeType"]) ?? "").hasPrefix("audio/mp4") && J.str(f["url"]) != nil
        }
        let defaults = audio.filter { f in
            guard let trackInfo = J.dict(f["audioTrack"]) else { return true }
            return (trackInfo["audioIsDefault"] as? Bool) ?? true
        }
        if !defaults.isEmpty { audio = defaults }
        if let best = audio.max(by: { (J.int($0["bitrate"]) ?? 0) < (J.int($1["bitrate"]) ?? 0) }),
           let u = J.str(best["url"]), let url = URL(string: u) {
            let itag = J.int(best["itag"]) ?? 0
            return AudioSource(url: url, headers: ["User-Agent": c.userAgent], label: "YouTube \(c.name), itag \(itag)")
        }

        // Último recurso: formato mixto (video + audio) en MP4.
        let muxed = (streaming["formats"] as? [[String: Any]]) ?? []
        let mixed = muxed.filter { f in
            (J.str(f["mimeType"]) ?? "").hasPrefix("video/mp4") && J.str(f["url"]) != nil
        }
        if let low = mixed.min(by: { (J.int($0["bitrate"]) ?? 0) < (J.int($1["bitrate"]) ?? 0) }),
           let u = J.str(low["url"]), let url = URL(string: u) {
            return AudioSource(url: url, headers: ["User-Agent": c.userAgent], label: "YouTube \(c.name), mp4 mixto")
        }
        throw BackendError.message("sin audio directo")
    }

    private func pipedAudio(_ base: String, _ id: String) async throws -> AudioSource {
        let any = try await getJSON("\(base)/streams/\(id)")
        guard let root = any as? [String: Any], let streams = root["audioStreams"] as? [[String: Any]] else {
            throw BackendError.message("sin audioStreams")
        }
        let m4a = streams.filter { s in
            let mime = (J.str(s["mimeType"]) ?? "").lowercased()
            let format = (J.str(s["format"]) ?? "").uppercased()
            return (mime.hasPrefix("audio/mp4") || format == "M4A") && J.str(s["url"]) != nil
        }
        guard let best = m4a.max(by: { (J.int($0["bitrate"]) ?? 0) < (J.int($1["bitrate"]) ?? 0) }),
              let u = J.str(best["url"]), let url = URL(string: u) else {
            throw BackendError.message("sin audio M4A")
        }
        return AudioSource(url: url, headers: [:], label: "Piped \(host(base))")
    }

    /// Pide los primeros bytes para confirmar que la URL responde antes de dársela al reproductor.
    private func probe(_ src: AudioSource) async -> Bool {
        var req = URLRequest(url: src.url)
        req.timeoutInterval = 10
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (k, v) in src.headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (_, resp) = try await session.bytes(for: req)
            if let http = resp as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) { return true }
                AppLog.shared.add("[probe] \(src.label): HTTP \(http.statusCode)")
                return false
            }
        } catch {
            AppLog.shared.add("[probe] \(src.label): \(error.localizedDescription)")
        }
        return false
    }
}
