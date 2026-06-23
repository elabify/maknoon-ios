// One per-(descriptor, network, sandwich) facade for Tron wallet
// operations. Mirrors `SolanaWallet` and `EthereumWallet`. Actor-
// isolated so the UI's `.task { await wallet.refresh() }` can stay
// on the main actor without races on the balance cache or in-flight
// URLSession.

import Foundation

actor TronWallet {
    let descriptor: TronWalletDescriptor
    let network: TronNetwork
    private let rpc: TronRPCClient
    private weak var sandwich: IdentitySandwich?

    /// Latest sun balance, or nil if not yet fetched.
    private(set) var sun: Int64?
    private(set) var lastSync: Date?
    private var cachedAddress: String?

    init(
        descriptor: TronWalletDescriptor,
        network: TronNetwork,
        rpcURL: String,
        sandwich: IdentitySandwich?
    ) {
        self.descriptor = descriptor
        self.network = network
        if let client = TronRPCClient(baseString: rpcURL) {
            self.rpc = client
        } else {
            // Fall back to the network's built-in default so a bad
            // user override doesn't brick the wallet view.
            self.rpc = TronRPCClient(base: URL(string: network.defaultRpcURL)!)
        }
        self.sandwich = sandwich
    }

    // MARK: -- read

    func address(biometricReason: String) throws -> String {
        switch descriptor.kind {
        case .software(let account):
            guard let sandwich else { throw SandwichError.masterUnavailable }
            return try TronDescriptors.addressFromSandwich(
                sandwich: sandwich,
                account: account,
                biometricReason: biometricReason
            )
        case .hardware(_, _, let addressBase58Check):
            return addressBase58Check
        }
    }

    /// Cache the derived address across a single dashboard refresh so
    /// the biometric prompt only fires once per screen open.
    func resolvedAddress(biometricReason: String) throws -> String {
        if let c = cachedAddress { return c }
        let a = try address(biometricReason: biometricReason)
        self.cachedAddress = a
        return a
    }

    func refreshBalance(biometricReason: String) async throws -> Int64 {
        let a = try resolvedAddress(biometricReason: biometricReason)
        let b = try await rpc.getBalance(addressBase58: a)
        self.sun = b
        self.lastSync = Date()
        return b
    }

    func recentTransactions(limit: Int = 10, biometricReason: String) async throws -> [TronRPCClient.TxRecord] {
        let a = try resolvedAddress(biometricReason: biometricReason)
        return try await rpc.getTransactionsByAddress(addressBase58: a, limit: limit)
    }

    /// Convenience pass-through for the block reference, used by the
    /// send view to build a signed transaction.
    func nowBlock() async throws -> TronRPCClient.NowBlock {
        try await rpc.getNowBlock()
    }

    // MARK: -- send

    /// Send native TRX. Returns the txid (hex) on success. The
    /// `feeLimitSun` cap protects against runaway energy burn on a
    /// transaction that ends up calling a contract path; for a pure
    /// transfer 1 TRX (1_000_000 sun) is more than enough.
    func sendNative(
        recipient: String,
        sunAmount: Int64,
        feeLimitSun: Int64 = 1_000_000,
        biometricReason: String
    ) async throws -> String {
        guard let sandwich else { throw SandwichError.masterUnavailable }
        guard case .software(let account) = descriptor.kind else {
            throw TronDescriptorError.signingFailed("Hardware Tron send not implemented in this build")
        }
        let sender = try resolvedAddress(biometricReason: biometricReason)
        let block = try await rpc.getNowBlock()
        let blockRef = try TronWallet.blockRef(from: block)
        let signedJSON = try TronDescriptors.signNativeTransferFromSandwich(
            sandwich: sandwich,
            account: account,
            senderBase58: sender,
            recipientBase58: recipient,
            sunAmount: sunAmount,
            blockRef: blockRef,
            feeLimitSun: feeLimitSun,
            biometricReason: biometricReason
        )
        return try await rpc.broadcastTransaction(signedJSON: signedJSON)
    }

    /// TRC-20 token transfer. Delegates to `TronTRC20TransferBuilder`
    /// for the ABI + TWC signing dance; this actor just provides the
    /// sandwich, sender, and block reference.
    func sendTRC20(
        contractAddress: String,
        decimals: UInt8,
        rawAmount: String,   // base-10 string, big enough for 18 decimals
        recipient: String,
        feeLimitSun: Int64 = 100_000_000,  // 100 TRX cap
        biometricReason: String
    ) async throws -> String {
        guard let sandwich else { throw SandwichError.masterUnavailable }
        guard case .software(let account) = descriptor.kind else {
            throw TronDescriptorError.signingFailed("Hardware Tron send not implemented in this build")
        }
        let sender = try resolvedAddress(biometricReason: biometricReason)
        let block = try await rpc.getNowBlock()
        let blockRef = try TronWallet.blockRef(from: block)
        let signedJSON = try TronTRC20TransferBuilder.sign(
            sandwich: sandwich,
            account: account,
            senderBase58: sender,
            contractBase58: contractAddress,
            recipientBase58: recipient,
            rawAmountDecimal: rawAmount,
            blockRef: blockRef,
            feeLimitSun: feeLimitSun,
            biometricReason: biometricReason
        )
        return try await rpc.broadcastTransaction(signedJSON: signedJSON)
    }

    /// One-shot hardware-backed native TRX transfer. Convenience
    /// wrapper around `prepareHardwareNative` + `broadcastHardwareSignature`.
    /// The send view uses the split form so it can show a
    /// "signed, awaiting broadcast" interstitial.
    func sendHardwareNative(
        recipient: String,
        sunAmount: Int64,
        feeLimitSun: Int64,
        ledger: HardwareWallet,
        senderBase58: String,
        account: UInt32
    ) async throws -> String {
        let signed = try await prepareHardwareNative(
            recipient: recipient,
            sunAmount: sunAmount,
            feeLimitSun: feeLimitSun,
            ledger: ledger,
            senderBase58: senderBase58,
            account: account
        )
        return try await broadcastHardwareSignature(signed)
    }

    /// Sign-only step of the hardware native send. Returns the
    /// envelope JSON + Ledger signature; the caller broadcasts
    /// separately via `broadcastHardwareSignature`.
    ///
    /// Routes through TronGrid's `/wallet/createtransaction` so
    /// the Ledger sees the exact raw_data bytes the network
    /// expects, bypassing the TWC `preImageHashes` quirk for Tron.
    func prepareHardwareNative(
        recipient: String,
        sunAmount: Int64,
        feeLimitSun: Int64,
        ledger: HardwareWallet,
        senderBase58: String,
        account: UInt32
    ) async throws -> TronDescriptors.TronUnsignedAndSignature {
        try await TronDescriptors.signNativeTransferOnHardware(
            rpc: rpc,
            ledger: ledger,
            account: account,
            senderBase58: senderBase58,
            recipientBase58: recipient,
            sunAmount: sunAmount,
            feeLimitSun: feeLimitSun
        )
    }

    /// Broadcast a Ledger-signed native transfer assembled by
    /// `prepareHardwareNative` or `prepareHardwareTRC20`. Splices
    /// the signature into the envelope JSON and POSTs to
    /// `/wallet/broadcasttransaction`.
    func broadcastHardwareSignature(
        _ signed: TronDescriptors.TronUnsignedAndSignature
    ) async throws -> String {
        try await rpc.broadcastWithSignature(
            envelopeJSON: signed.envelopeJSON,
            signatureRSV: signed.signatureRSV
        )
    }

    /// Hardware-signed TRC-20 token transfer. Same shape as the
    /// native version: TronGrid builds the unsigned tx (via
    /// `/wallet/triggersmartcontract`), Ledger signs it, broadcast
    /// caller splices and POSTs. Note: the Ledger Tron app may
    /// require the user to enable "Custom contracts" in app
    /// settings if the token isn't on its known-allowlist.
    func prepareHardwareTRC20(
        contractAddress: String,
        recipient: String,
        rawAmount: String,
        feeLimitSun: Int64,
        ledger: HardwareWallet,
        senderBase58: String,
        account: UInt32
    ) async throws -> TronDescriptors.TronUnsignedAndSignature {
        let unsigned = try await rpc.createTRC20Transaction(
            senderBase58: senderBase58,
            contractAddressBase58: contractAddress,
            recipientBase58: recipient,
            rawAmount: rawAmount,
            feeLimitSun: feeLimitSun
        )
        let sig = try await ledger.signTronTransaction(
            rawTxProto: unsigned.rawData,
            account: account
        )
        guard sig.r.count == 32, sig.s.count == 32 else {
            throw TronDescriptorError.signingFailed(
                "Ledger returned malformed signature components"
            )
        }
        var signatureRSV = Data()
        signatureRSV.append(sig.r)
        signatureRSV.append(sig.s)
        signatureRSV.append(sig.v)
        return TronDescriptors.TronUnsignedAndSignature(
            envelopeJSON: unsigned.envelopeJSON,
            signatureRSV: signatureRSV
        )
    }

    /// Software path's sign-only step. Mirrors `prepareHardwareNative`.
    func prepareSoftwareNative(
        recipient: String,
        sunAmount: Int64,
        feeLimitSun: Int64,
        biometricReason: String
    ) async throws -> String {
        guard let sandwich else { throw SandwichError.masterUnavailable }
        guard case .software(let account) = descriptor.kind else {
            throw TronDescriptorError.signingFailed("Wallet is hardware-backed; software sign not applicable")
        }
        let sender = try resolvedAddress(biometricReason: biometricReason)
        let block = try await rpc.getNowBlock()
        let blockRef = try TronWallet.blockRef(from: block)
        return try TronDescriptors.signNativeTransferFromSandwich(
            sandwich: sandwich,
            account: account,
            senderBase58: sender,
            recipientBase58: recipient,
            sunAmount: sunAmount,
            blockRef: blockRef,
            feeLimitSun: feeLimitSun,
            biometricReason: biometricReason
        )
    }

    /// Software path's sign-only step for TRC-20. Mirrors
    /// `prepareSoftwareNative`; returns the wire-ready signed JSON
    /// (with `txID`) for `broadcastSignedJSON`. Used by the commerce
    /// flow so identity + the pre-broadcast txID can be posted before
    /// money moves.
    func prepareSoftwareTRC20(
        contractAddress: String,
        rawAmount: String,
        recipient: String,
        feeLimitSun: Int64 = 100_000_000,
        biometricReason: String
    ) async throws -> String {
        guard let sandwich else { throw SandwichError.masterUnavailable }
        guard case .software(let account) = descriptor.kind else {
            throw TronDescriptorError.signingFailed("Wallet is hardware-backed; software sign not applicable")
        }
        let sender = try resolvedAddress(biometricReason: biometricReason)
        let block = try await rpc.getNowBlock()
        let blockRef = try TronWallet.blockRef(from: block)
        return try TronTRC20TransferBuilder.sign(
            sandwich: sandwich,
            account: account,
            senderBase58: sender,
            contractBase58: contractAddress,
            recipientBase58: recipient,
            rawAmountDecimal: rawAmount,
            blockRef: blockRef,
            feeLimitSun: feeLimitSun,
            biometricReason: biometricReason
        )
    }

    /// Broadcast a pre-signed transaction JSON. Idempotent on the
    /// caller's side: the same signed tx can be retried if the
    /// initial broadcast errored on transport (TronGrid will return
    /// "tx already in pool" the second time, which the caller can
    /// treat as success).
    func broadcastSignedJSON(_ signedJSON: String) async throws -> String {
        try await rpc.broadcastTransaction(signedJSON: signedJSON)
    }

    /// Decoded block reference for `TronDescriptors.signNativeTransferFromSandwich`.
    static func blockRef(from block: TronRPCClient.NowBlock) throws -> TronBlockRef {
        return TronBlockRef(
            number: block.number,
            timestamp: block.timestamp,
            parentHash: Data(hex: block.parentHashHex),
            txTrieRoot: Data(hex: block.txTrieRootHex),
            witnessAddress: Data(hex: block.witnessAddressHex),
            version: block.version
        )
    }
}

// MARK: -- hex helper

private extension Data {
    init(hex: String) {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let next = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let b = UInt8(cleaned[i..<next], radix: 16) { bytes.append(b) }
            i = next
        }
        self.init(bytes)
    }
}
