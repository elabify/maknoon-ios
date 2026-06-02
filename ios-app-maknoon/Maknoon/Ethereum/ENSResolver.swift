// ENS (Ethereum Name Service) → 0x-address resolver.
//
// ENS lives on Ethereum mainnet (chain id 1). Even when you're
// sending on Sepolia or an L2, ENS resolution still happens
// against mainnet because that's where the registry contracts
// live and where names are owned. We expose a configurable RPC
// URL (defaulting to whatever the mainnet RPC is set to in
// EthereumSettings) so users can route resolution through their
// own node.
//
// L1 resolution path: ENS Registry → Resolver → addr(node). No
// ENSIP-10 wildcard / CCIP-read in this cut; those land in L2 if
// any of the user's saved names turn out to be off-chain.

import Foundation
import WalletCore

enum ENSError: LocalizedError {
    case malformedName
    case noResolver
    case noAddress
    case rpcDown(String)
    case badResponse(String)
    case configMissing

    var errorDescription: String? {
        switch self {
        case .malformedName:
            return "That doesn't look like a valid ENS name. Use the form name.eth (or any ENS-supported TLD)."
        case .noResolver:
            return "ENS Registry has no resolver set for that name. The owner needs to set a public resolver before it can be used."
        case .noAddress:
            return "That ENS name has no Ethereum address record. The owner needs to set the addr() record on the resolver."
        case .rpcDown(let s):
            return "Couldn't reach the ENS gateway: \(s). Check Settings → Networks → Ethereum → ENS gateway."
        case .badResponse(let s):
            return "Unexpected ENS response: \(s)"
        case .configMissing:
            return "No ENS gateway configured. Set one in Settings → Networks → Ethereum → ENS gateway."
        }
    }
}

struct ENSResolver: Sendable {
    /// JSON-RPC endpoint pointing at an Ethereum mainnet node (or
    /// a personal gateway). ENS is mainnet-only even when sending
    /// on L2s.
    let rpcURL: URL

    /// Canonical ENS Registry on Ethereum mainnet. The registry
    /// address itself has been stable across the ENS v1 → ENSv2
    /// migration; it always exposes `resolver(bytes32)`.
    static let registryAddress = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"

    init?(rpcURLString: String) {
        guard let url = URL(string: rpcURLString) else { return nil }
        self.rpcURL = url
    }

    /// Heuristic: looks like a name we should try ENS for? Avoids
    /// firing off an RPC call for plain 0x… input.
    static func looksLikeName(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("0x") { return false }
        // Has a dot AND no spaces; the last label is at least 2 chars.
        guard trimmed.contains("."), !trimmed.contains(" ") else { return false }
        let labels = trimmed.split(separator: ".")
        return labels.count >= 2 && labels.last!.count >= 2
    }

    /// Resolve `name.eth` to a checksummed 0x address. Two-call
    /// flow:
    ///   1. registry.resolver(namehash) → resolver address
    ///   2. resolver.addr(namehash)     → owner address
    func resolve(_ name: String) async throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.looksLikeName(normalized) else { throw ENSError.malformedName }
        let node = try Self.namehash(normalized)

        guard let rpc = EthereumRPCClient(urlString: rpcURL.absoluteString) else {
            throw ENSError.configMissing
        }

        // resolver(bytes32 node) - selector 0x0178b8bf
        let resolverCallData = Self.callData(selectorHex: "0178b8bf", argHex32: node.hexString)
        let resolverResp: String
        do {
            resolverResp = try await rpc.ethCall(to: Self.registryAddress, data: resolverCallData)
        } catch {
            throw ENSError.rpcDown(error.localizedDescription)
        }
        guard let resolverAddr = Self.addressFromCallResult(resolverResp) else {
            throw ENSError.badResponse(resolverResp)
        }
        if resolverAddr == "0x0000000000000000000000000000000000000000" {
            throw ENSError.noResolver
        }

        // addr(bytes32 node) - selector 0x3b3b57de
        let addrCallData = Self.callData(selectorHex: "3b3b57de", argHex32: node.hexString)
        let addrResp: String
        do {
            addrResp = try await rpc.ethCall(to: resolverAddr, data: addrCallData)
        } catch {
            throw ENSError.rpcDown(error.localizedDescription)
        }
        guard let address = Self.addressFromCallResult(addrResp) else {
            throw ENSError.badResponse(addrResp)
        }
        if address == "0x0000000000000000000000000000000000000000" {
            throw ENSError.noAddress
        }
        return EIP55.checksum(address)
    }

    // MARK: -- helpers

    /// ENS namehash per EIP-137. Recursive keccak256 over UTF-8
    /// labels, starting from the empty 32-zero-byte node.
    static func namehash(_ name: String) throws -> Data {
        var node = Data(repeating: 0, count: 32)
        if name.isEmpty { return node }
        let labels = name.split(separator: ".").map(String.init)
        for label in labels.reversed() {
            let labelHash = Hash.keccak256(data: Data(label.utf8))
            node = Hash.keccak256(data: node + labelHash)
        }
        return node
    }

    /// Build calldata: 4-byte selector || 32-byte argument.
    private static func callData(selectorHex: String, argHex32: String) -> Data {
        var hex = selectorHex
        let arg = argHex32.replacingOccurrences(of: "0x", with: "")
        if arg.count < 64 {
            hex += String(repeating: "0", count: 64 - arg.count) + arg
        } else {
            hex += String(arg.suffix(64))
        }
        return Data(hexString: hex) ?? Data()
    }

    /// Pull the rightmost 20 bytes out of an eth_call result.
    private static func addressFromCallResult(_ hex: String) -> String? {
        let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard s.count >= 64 else { return nil }
        let last40 = String(s.suffix(40))
        return "0x" + last40
    }
}

/// EIP-55 address checksum. Implemented in-place rather than
/// reused from somewhere because the existing usage (in LedgerBLE)
/// already does this inline; centralising would touch unrelated
/// code.
enum EIP55 {
    static func checksum(_ address: String) -> String {
        let s = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        let lower = s.lowercased()
        let hash = Hash.keccak256(data: Data(lower.utf8))
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        var out = "0x"
        for (i, ch) in lower.enumerated() {
            if ch.isLetter, let n = Int(String(hashHex[hashHex.index(hashHex.startIndex, offsetBy: i)]), radix: 16), n >= 8 {
                out.append(Character(ch.uppercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

private extension Data {
    init?(hexString: String) {
        let s = hexString.replacingOccurrences(of: "0x", with: "")
        guard s.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self = Data(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
