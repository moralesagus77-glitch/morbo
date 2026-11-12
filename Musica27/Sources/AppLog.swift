import Foundation

/// Registro de eventos visible en Ajustes, para poder ver por qué falla algo.
final class AppLog: ObservableObject {
    static let shared = AppLog()

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ text: String) {
        let line = "\(formatter.string(from: Date())) \(text)"
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 300 {
                self.lines.removeFirst(self.lines.count - 300)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.lines.removeAll()
        }
    }
}
