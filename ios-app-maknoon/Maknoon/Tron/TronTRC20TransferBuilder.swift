// Signs a TRC-20 token transfer under the sandwich seed and returns
// the broadcast-ready signed JSON. Mirrors
// `SolanaSPLTransferBuilder` for SPL: keeps the ABI + signing math
// in one place so the wallet actor just routes through `sign(...)`
// without owning the TWC import.
//
// TWC's `TronTransferTRC20Contract` does most of the heavy lifting:
// give it owner / contract / to / amount-as-Data, it emits the
// proper TriggerSmartContract instruction with the
// `transfer(address,uint256)` ABI under the hood.

import Foundation
import WalletCore

enum TronTRC20TransferError: LocalizedError {
    case invalidContract(String)
    case invalidRecipient(String)
    case amountTooLarge
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidContract(let s):   return "Invalid TRC-20 contract address: \(s)"
        case .invalidRecipient(let s):  return "Invalid recipient address: \(s)"
        case .amountTooLarge:           return "Amount exceeds 256-bit unsigned range"
        case .signingFailed(let m):     return "TRC-20 signing failed: \(m)"
        }
    }
}

enum TronTRC20TransferBuilder {

    /// Sign a TRC-20 transfer. `rawAmountDecimal` is the on-chain
    /// integer amount as a base-10 string (so "1.00 USDT" with 6
    /// decimals is "1000000"). String avoids UInt64 overflow on
    /// 18-decimal tokens.
    static func sign(
        sandwich: IdentitySandwich,
        account: UInt32,
        senderBase58: String,
        contractBase58: String,
        recipientBase58: String,
        rawAmountDecimal: String,
        blockRef: TronBlockRef,
        feeLimitSun: Int64,
        biometricReason: String
    ) throws -> String {
        guard WalletCore.AnyAddress(string: contractBase58, coin: .tron) != nil else {
            throw TronTRC20TransferError.invalidContract(contractBase58)
        }
        guard WalletCore.AnyAddress(string: recipientBase58, coin: .tron) != nil else {
            throw TronTRC20TransferError.invalidRecipient(recipientBase58)
        }
        // Convert the base-10 amount string to a big-endian byte
        // sequence. TWC accepts the amount as Data so 256-bit values
        // pass through cleanly.
        guard let amountData = bigEndianBytes(decimalString: rawAmountDecimal, maxBytes: 32) else {
            throw TronTRC20TransferError.amountTooLarge
        }

        let material = try sandwich.recoveryMaterial(localizedReason: biometricReason)
        let words = material.words.joined(separator: " ")
        guard let wallet = WalletCore.HDWallet(
            mnemonic: words,
            passphrase: material.hasPassphrase ? material.passphrase : ""
        ) else {
            throw TronTRC20TransferError.signingFailed("HDWallet init returned nil")
        }
        let priv = wallet.getKeyByCurve(
            curve: .secp256k1,
            derivationPath: TronDescriptors.derivationPath(account: account)
        )

        var input = WalletCore.TronSigningInput()
        input.privateKey = priv.data

        var tx = WalletCore.TronTransaction()
        tx.timestamp = blockRef.timestamp
        tx.expiration = blockRef.timestamp + 60_000
        tx.feeLimit = feeLimitSun
        tx.blockHeader = TronDescriptors.makeBlockHeader(blockRef)

        var transfer = WalletCore.TronTransferTRC20Contract()
        transfer.contractAddress = contractBase58
        transfer.ownerAddress = senderBase58
        transfer.toAddress = recipientBase58
        transfer.amount = amountData
        tx.contractOneof = .transferTrc20Contract(transfer)

        input.transaction = tx
        let output: WalletCore.TronSigningOutput = WalletCore.AnySigner.sign(input: input, coin: .tron)
        if !output.errorMessage.isEmpty {
            throw TronTRC20TransferError.signingFailed(output.errorMessage)
        }
        return output.json
    }

    /// Big-endian bytes for an arbitrary-precision decimal string.
    /// Returns nil if the value won't fit in `maxBytes` (256 bits =
    /// 32 bytes for TRC-20).
    static func bigEndianBytes(decimalString: String, maxBytes: Int) -> Data? {
        let trimmed = decimalString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }) else { return nil }
        if trimmed == "0" { return Data([0]) }
        // Convert by repeated divide-by-256.
        var digits = Array(trimmed).compactMap { $0.wholeNumberValue }
        var bytes: [UInt8] = []
        while !digits.isEmpty {
            var rem = 0
            var nextDigits: [Int] = []
            for d in digits {
                let cur = rem * 10 + d
                let q = cur / 256
                rem = cur % 256
                if !(nextDigits.isEmpty && q == 0) {
                    nextDigits.append(q)
                }
            }
            bytes.append(UInt8(rem))
            digits = nextDigits
        }
        if bytes.count > maxBytes { return nil }
        return Data(bytes.reversed())
    }

    /// Parameter encoding for the `triggerConstantContract` balanceOf
    /// probe used by the dashboard's token-balance walk. ABI encodes
    /// a Tron address as a 32-byte zero-padded EVM-style address:
    /// the 20-byte hash, left-padded to 32 bytes.
    ///
    /// TWC's `AnyAddress(string:coin:.tron).data` returns the bare
    /// 20-byte hash (no `0x41` network prefix). Earlier revisions of
    /// this helper assumed the 21-byte network-prefixed form and
    /// silently returned nil for the 20-byte case, which made every
    /// TRC-20 balance read return 0 even when the wallet held
    /// tokens. The branch below accepts either shape so a future
    /// TWC change in either direction stays harmless.
    static func encodeAddressParameter(base58: String) -> String? {
        // Earlier revision tried `AnyAddress(string:coin:.tron).data`
        // here, but TWC's AnyAddress returns empty Data for Tron
        // addresses (confirmed via on-device diagnostic log). Use
        // the base58check decoder directly: a Tron address always
        // decodes to exactly 21 bytes, `[0x41, 20-byte hash]`. ABI
        // encoding drops the network byte and left-pads the hash to
        // 32 bytes.
        guard let raw = WalletCore.Base58.decode(string: base58),
              raw.count == 21,
              raw.first == 0x41
        else {
            return nil
        }
        let twenty = raw.dropFirst()
        let pad = Data(repeating: 0, count: 32 - twenty.count)
        return (pad + twenty).map { String(format: "%02x", $0) }.joined()
    }

    /// Read a holder's TRC-20 balance via `balanceOf(address)`,
    /// returning the raw on-chain integer as a base-10 string (the
    /// shape `TronTRC20Token.format(rawAmountDecimal:)` expects).
    /// Returns "0" on any RPC / decode failure so callers can render
    /// a balance line without special-casing errors. Lifted out of
    /// TronWalletView so the token detail + send views can share it.
    static func balance(
        holderBase58: String,
        contractBase58: String,
        rpcURL: String
    ) async throws -> String {
        guard let rpc = TronRPCClient(baseString: rpcURL) else { return "0" }
        guard let parameter = encodeAddressParameter(base58: holderBase58) else { return "0" }
        let hex = try await rpc.triggerConstantContract(
            ownerAddressBase58: holderBase58,
            contractAddressBase58: contractBase58,
            functionSelector: "balanceOf(address)",
            parameterHex: parameter
        )
        let cleaned = hex.lowercased().hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard !cleaned.isEmpty else { return "0" }
        var result = Decimal(0)
        for ch in cleaned {
            guard let d = Int(String(ch), radix: 16) else { continue }
            result = result * 16 + Decimal(d)
        }
        return "\(result)"
    }
}
