// Auto-detect SPL token metadata from a mint address by reading
// the on-chain SPL Token Mint account via `getAccountInfo` with
// `jsonParsed` encoding. Solana SPL Mints carry `decimals` directly
// (the most error-prone field to get wrong by hand); `symbol` and
// `name` aren't on the mint, they live in a separate Metaplex
// Token Metadata account that requires PDA derivation + Borsh
// decode. We surface decimals here and let the user fill in
// symbol/name unless the catalog already had them.

import Foundation

struct SPLMintMetadata: Sendable, Hashable {
    let decimals: UInt8
    /// Total supply as a raw on-chain integer (decimal string). Not
    /// rendered today but kept so the AddTokenSheet can show a quick
    /// sanity-check ("Mint exists with N raw units supply"). Useful
    /// when the mint authority has revoked or never deployed.
    let supplyRaw: String
}

enum SolanaTokenLookup {

    /// Hit the configured RPC for the mint's parsed account info.
    /// Returns nil for: bad URL, non-existent address, not an
    /// `spl-token` mint, or transport failure. The caller falls back
    /// to manual symbol/name + decimals entry when nil.
    static func fetch(mint: String, rpcURL: String) async -> SPLMintMetadata? {
        guard let url = URL(string: rpcURL) else { return nil }
        let rpc = SolanaRPCClient(endpoint: url)
        do {
            guard let parsed = try await rpc.getParsedMint(address: mint) else {
                return nil
            }
            return SPLMintMetadata(
                decimals: parsed.decimals,
                supplyRaw: parsed.supplyRaw
            )
        } catch {
            return nil
        }
    }
}
