import Foundation
import Security

enum Keychain {
    static let service = "dev.yask.decks"
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct JevAnswer: Sendable {
    var move: String
    var probs: [(String, Double)]
    var confidence: Double?
    var scratch: String?
    var hype: Int
    var ms: Double
    var model: String
}

/// Jev (TypeSafe's System One model) through OpenRouter's /api/v1/systemone passthrough: typed questions in, typed answers out.
enum Jev {
    static let model = "typesafe/jev-1.13"

    static func decide(state: [String: Any], moves: [String: String], styles: [String: String], key: String) async throws -> JevAnswer {
        var questions: [String: Any] = [
            "move": ["type": "choice",
                     "instructions": "You are the DJ. Pick the move for the upcoming bar that makes this set most exciting right now, respecting `timing`, avoiding `recent_moves` repeats.",
                     "criteria": moves],
            "hype": ["type": "score", "instructions": "How big should the next moment hit?",
                     "criteria": ["keep it smooth", "steady groove", "hype", "peak — go all out"]],
        ]
        if !styles.isEmpty {
            questions["scratch"] = ["type": "choice", "instructions": "If this bar involves scratching, which technique sounds best here?", "criteria": styles]
        }
        let body: [String: Any] = ["model": model, "state": state, "questions": questions]
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/systemone")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://yask.dev/dj", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Decks", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms = Date().timeIntervalSince(t0) * 1000
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["answers"] as? [String: Any],
              let mv = answers["move"] as? [String: Any], let choice = mv["choice"] as? String else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "bad response"])
        }
        let probs = ((mv["probabilities"] as? [String: Double]) ?? [:]).sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let sc = (answers["scratch"] as? [String: Any])?["choice"] as? String
        let hype = ((answers["hype"] as? [String: Any])?["score"] as? Double).map { Int($0.rounded()) } ?? 2
        return JevAnswer(move: choice, probs: probs, confidence: mv["confidence"] as? Double, scratch: sc, hype: hype, ms: ms,
                         model: obj["model"] as? String ?? model)
    }
}
