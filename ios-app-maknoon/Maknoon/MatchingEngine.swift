// Pure-function credential filtering for the open-verifier flow. Given the
// holder's wallet contents and a verifier's filter spec, returns the
// credentials that satisfy ALL three dimensions: issuer, schema, required
// claims. Mirrors the React/TS implementation in `shared/MatchingEngine.ts`
// (Slice 10) so the two surfaces agree on what counts as a match.
//
// Filter semantics:
//   - issuers / schemas: a `wildcard` clause matches anything; an `allow`
//     clause matches only values that appear in `list`. Absent clauses
//     are wildcards (no constraint on that dimension).
//   - requiredClaims: every key must be present in the credential's claims
//     map. The values are NOT inspected; presence is sufficient. Predicates
//     are out of scope per ADR-0028; Phase 0 leans on derived claims like
//     `over18` for "is this person old enough" checks.

import Foundation

enum MatchingEngine {

    /// Filter `credentials` to those that satisfy `filter`.
    static func match(credentials: [Credential], filter: VerifierFilter) -> [Credential] {
        return credentials.filter { matches(credential: $0, filter: filter) }
    }

    /// True iff `credential` satisfies every dimension of `filter`.
    static func matches(credential c: Credential, filter f: VerifierFilter) -> Bool {
        if let issuers = f.issuers, !clausePasses(issuers, value: c.header.iss) { return false }
        if let schemas = f.schemas, !clausePasses(schemas, value: c.header.schema) { return false }
        for required in f.requiredClaims {
            if c.claims[required] == nil { return false }
        }
        return true
    }

    /// True iff `value` is accepted by `clause`. Unknown modes fail closed.
    private static func clausePasses(_ clause: VerifierFilterClause, value: String) -> Bool {
        switch clause.mode {
        case "wildcard": return true
        case "allow":    return (clause.list ?? []).contains(value)
        default:         return false
        }
    }
}
