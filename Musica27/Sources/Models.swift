import Foundation

/// Una canción (o video) de YouTube Music.
struct Track: Identifiable, Hashable {
    let id: String            // videoId de YouTube
    var title: String
    var artist: String
    var duration: Double?     // en segundos
    var thumbnail: URL?

    var artworkURL: URL? {
        if let t = thumbnail { return t }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }
}

enum Fmt {
    static func time(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds < 0 { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, r) }
        return String(format: "%d:%02d", m, r)
    }

    /// "3:45" -> 225. Devuelve nil si el texto no parece una duración.
    static func parseTime(_ text: String) -> Double? {
        guard text.contains(":") else { return nil }
        var total = 0
        for piece in text.split(separator: ":") {
            guard let n = Int(piece) else { return nil }
            total = total * 60 + n
        }
        return Double(total)
    }
}
