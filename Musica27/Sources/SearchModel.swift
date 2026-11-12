import Foundation

final class SearchModel: ObservableObject {
    @Published var results: [Track] = []
    @Published var loading = false
    @Published var message: String?

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loading = true
        message = nil
        Task { [weak self] in
            do {
                let found = try await Backend.shared.search(q)
                await MainActor.run {
                    self?.results = found
                    self?.loading = false
                    if found.isEmpty { self?.message = "No hay resultados para “\(q)”." }
                }
            } catch {
                let text = error.localizedDescription
                await MainActor.run {
                    self?.loading = false
                    self?.message = text
                }
            }
        }
    }
}
