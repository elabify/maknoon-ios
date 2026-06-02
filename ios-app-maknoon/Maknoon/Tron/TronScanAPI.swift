// TronScan account-index API. Independent of the TronGrid RPC the
// rest of the Tron stack uses; lives in its own helper so the
// dependency footprint stays explicit. Used today for one job:
// auto-discovering the list of TRC-20 contracts a given address
// holds, so the dashboard can reconcile that list against the
// verified catalog without making the user paste each contract.
//
// Mainnet-only. TronScan does not publish a Shasta / Nile-equivalent
// API host, so the dashboard skips this discovery on testnets and
// users add testnet tokens manually via the Add Token sheet.

import Foundation

enum TronScanAPI {

    /// One held TRC-20 row from the TronScan account index.
    struct HeldTRC20: Sendable, Hashable {
        let contract: String     // T-prefixed base58
        let symbol: String
        let name: String
        let decimals: UInt8
        let amount: String       // raw on-chain integer, base-10 string
        let logoURL: String?
    }

    /// Walk a wallet's TRC-20 holdings via TronScan's `/api/account`
    /// endpoint. Returns the parsed list with raw amounts; the
    /// caller decides whether to auto-install each one against the
    /// verified catalog or surface it as Unknown.
    ///
    /// Mainnet-only. Throws CancellationError to honour Swift task
    /// cancellation, otherwise wraps transport failures in
    /// TronRPCError for parity with the rest of the Tron stack.
    static func discoverHeldTRC20(addressBase58: String) async throws -> [HeldTRC20] {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://apilist.tronscanapi.com/api/account")
        components?.queryItems = [
            URLQueryItem(name: "address", value: addressBase58),
            URLQueryItem(name: "showAssetList", value: "true"),
        ]
        guard let url = components?.url else {
            throw TronRPCError.badURL("apilist.tronscanapi.com")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TronRPCError.transport(error.localizedDescription)
        }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TronRPCError.transport("HTTP \(http.statusCode) from TronScan")
        }
        struct Envelope: Decodable {
            let trc20token_balances: [Row]?
            struct Row: Decodable {
                let tokenId: String?
                let balance: String?
                let tokenName: String?
                let tokenAbbr: String?
                let tokenDecimal: AnyOptionalInt?
                let tokenLogo: String?
                let tokenCanShow: AnyOptionalInt?
                let tokenType: String?
            }
        }
        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            var out: [HeldTRC20] = []
            for row in env.trc20token_balances ?? [] {
                guard let contract = row.tokenId,
                      let amount = row.balance,
                      let symbol = row.tokenAbbr,
                      let name = row.tokenName
                else { continue }
                let decimals = UInt8(clamping: row.tokenDecimal?.value ?? 0)
                out.append(HeldTRC20(
                    contract: contract,
                    symbol: symbol,
                    name: name,
                    decimals: decimals,
                    amount: amount,
                    logoURL: row.tokenLogo
                ))
            }
            return out
        } catch {
            throw TronRPCError.decode("TronScan account JSON: \(error.localizedDescription)")
        }
    }
}
