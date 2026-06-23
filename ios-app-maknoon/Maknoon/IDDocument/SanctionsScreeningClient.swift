// Opt-in OpenSanctions screening for a scanned passport.
//
// The holder taps "Check against OpenSanctions" in the document detail
// view; we POST the name + date of birth + nationality to the issuer's
// /v1/sanctions-check endpoint (the issuer proxies the self-hosted
// yente matcher so passport PII never goes to a third party). The
// outcome is persisted on the IDDocument and surfaced as a shield
// badge on the card.
//
// This is screening only, it does NOT mint a credential. The user can
// run it before or after issuing a verified credential; the issuer
// independently screens at issuance time regardless.

import Foundation

/// Coarse screening outcome, mirroring the issuer's SanctionsOutcome.
enum SanctionsOutcome: String, Codable, Sendable, Hashable {
    case clean
    case sanctioned
    case pep
    case inconclusive
    case error
}

/// One matched OpenSanctions entity, surfaced to the holder so a
/// non-clean result isn't an opaque "you're flagged". The issuer's
/// holder-facing endpoint returns the outcome only (no match detail),
/// so `matches` is usually empty for holder-run screens; it's kept on
/// the model so a future richer surface can populate it.
struct SanctionsMatchDetail: Codable, Sendable, Hashable {
    let name: String
    let listName: String
}

/// Persisted screening result on an IDDocument.
struct SanctionsScreenResult: Codable, Sendable, Hashable {
    let outcome: SanctionsOutcome
    /// When the screen was performed.
    let screenedAt: Date
    /// OpenSanctions dataset version the issuer screened against.
    let datasetVersion: String
    /// Optional match detail (empty for holder-run screens today).
    var matches: [SanctionsMatchDetail]

    /// Human label for the badge / detail row.
    var label: String {
        switch outcome {
        case .clean:        return "Clean"
        case .sanctioned:   return "Sanctioned"
        case .pep:          return "PEP match"
        case .inconclusive: return "Inconclusive"
        case .error:        return "Screening error"
        }
    }
}

enum SanctionsScreeningError: LocalizedError {
    case screeningDisabled
    case requestFailed(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .screeningDisabled:
            return "This issuer has sanctions screening turned off."
        case .requestFailed(let m):
            return "Screening request failed: \(m)"
        case .malformedResponse(let m):
            return "Unexpected response from the screening service: \(m)"
        }
    }
}

enum SanctionsScreeningClient {
    private struct CheckRequest: Encodable {
        let givenName: String
        let familyName: String
        let dateOfBirth: String   // ISO 8601 date YYYY-MM-DD
        let nationality: String?
    }

    private struct CheckResponse: Decodable {
        let v: Int
        let result: String?
        let screenedAt: Double?
        let datasetVersion: String?
        let error: String?
    }

    /// Screen a subject against the issuer's OpenSanctions proxy.
    /// `issuerBaseURL` is the same base the issuance flow uses
    /// (e.g. https://musnad-issuer1.elabify.com).
    static func check(
        givenName: String,
        familyName: String,
        dateOfBirth: String,
        nationality: String?,
        issuerBaseURL: URL,
    ) async throws -> SanctionsScreenResult {
        let url = issuerBaseURL.appendingPathComponent("v1/sanctions-check")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONEncoder().encode(
            CheckRequest(
                givenName: givenName,
                familyName: familyName,
                dateOfBirth: dateOfBirth,
                nationality: nationality,
            ),
        )

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw SanctionsScreeningError.malformedResponse("no HTTP response")
        }
        if http.statusCode == 503 {
            throw SanctionsScreeningError.screeningDisabled
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SanctionsScreeningError.requestFailed("HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let decoded: CheckResponse
        do {
            decoded = try JSONDecoder().decode(CheckResponse.self, from: data)
        } catch {
            throw SanctionsScreeningError.malformedResponse("\(error)")
        }
        guard let resultStr = decoded.result, let outcome = SanctionsOutcome(rawValue: resultStr) else {
            throw SanctionsScreeningError.malformedResponse("missing or unknown result: \(decoded.result ?? "nil")")
        }
        let screenedAt = decoded.screenedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return SanctionsScreenResult(
            outcome: outcome,
            screenedAt: screenedAt,
            datasetVersion: decoded.datasetVersion ?? "unknown",
            matches: [],
        )
    }
}
