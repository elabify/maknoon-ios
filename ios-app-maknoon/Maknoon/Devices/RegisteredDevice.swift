// Cross-vendor model for "a hardware security device the user has
// registered with Maknoon."
//
// Registration is a lightweight handshake: connect to the device just
// long enough to read a stable identifier ("serial") so we can
// recognise it next time. We do NOT enroll the device into anything
// at this stage. Promotion of a registered device into either:
//
//   - the Identity Sandwich (the device wraps the BIP39 entropy, so
//     it becomes a second factor for unlock), or
//   - a network (Bitcoin / Ethereum / ... wallet creation)
//
// is a separate, explicit action that the user performs from the
// device-detail screen or from the per-network settings page. Each
// promotion requires re-connecting to the device, confirming the
// same serial, and asking the user to open the right app on the
// device (Security Key / FIDO2 app for Identity, Bitcoin app for the
// Bitcoin network, Ethereum app for the Ethereum network).
//
// The same lifecycle is used for YubiKey, Ledger, and Trezor; the
// only difference is which kinds of promotions each device supports
// (see `DeviceKind.capabilities`).

import Foundation

enum DeviceKind: String, Codable, CaseIterable, Sendable {
    case yubikey
    case ledger
    case trezor
    /// Air-gapped Bitcoin-only signer. No live transport; all
    /// data crosses the air gap as QR codes via the phone's
    /// camera. Registration captures the xpub + master
    /// fingerprint as the device's stable serial.
    case seedsigner

    /// Device kinds the user can register today, sorted alphabetically
    /// by display name for the registration picker. Trezor is offered
    /// now that its THP v2 BLE client ships; registration runs a
    /// read-only handshake probe to confirm the connection.
    static var registrableCases: [DeviceKind] {
        allCases.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var displayName: String {
        switch self {
        case .yubikey:    return "YubiKey"
        case .ledger:     return "Ledger Nano X"
        case .trezor:     return "Trezor"
        case .seedsigner: return "SeedSigner"
        }
    }

    var systemImage: String {
        switch self {
        case .yubikey:    return "key.radiowaves.forward.fill"
        case .ledger:     return "externaldrive.connected.to.line.below.fill"
        case .trezor:     return "shield.righthalf.filled"
        case .seedsigner: return "qrcode.viewfinder"
        }
    }

    /// What this device can be promoted into. Per the user model:
    /// YubiKey wraps the Identity Sandwich; Ledger / Trezor sign
    /// transactions on chain-specific networks. (Ledger CAN do FIDO2
    /// via its "Security Key" app, so it can also wrap identity; we
    /// model that here so promotion UX is uniform.)
    struct Capabilities: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let identity = Capabilities(rawValue: 1 << 0)
        static let bitcoin  = Capabilities(rawValue: 1 << 1)
        static let ethereum = Capabilities(rawValue: 1 << 2)
        static let solana   = Capabilities(rawValue: 1 << 3)
        static let tron     = Capabilities(rawValue: 1 << 4)
    }

    var capabilities: Capabilities {
        switch self {
        case .yubikey:    return [.identity]
        case .ledger:     return [.identity, .bitcoin, .ethereum, .solana, .tron]
        case .trezor:     return [.identity, .bitcoin, .ethereum, .solana, .tron]
        case .seedsigner: return [.bitcoin]
        }
    }

    /// How this device signs a Bitcoin transaction. Drives the Send
    /// button in BitcoinSendView so a Ledger user sees a BLE-sign
    /// button instead of being shunted into the offline-PSBT path
    /// the way the air-gapped SeedSigner is.
    var bitcoinSigningMechanism: BitcoinSigningMechanism {
        switch self {
        case .ledger, .trezor: return .hardwareBLE
        case .seedsigner:      return .airgappedPSBT
        case .yubikey:         return .airgappedPSBT  // never used; yubikey can't bitcoin
        }
    }
}

/// What kind of signing flow Maknoon should run for a given Bitcoin
/// wallet's transactions. Lives at the device level so a wallet's
/// signing UX is determined by the device it was created from.
enum BitcoinSigningMechanism: Hashable, Sendable {
    /// On-phone software signing. Used by software wallets and only
    /// by software wallets, never the hardware path.
    case software
    /// Hardware wallet over a live transport (BLE for Ledger /
    /// Trezor). Maknoon connects, sends the PSBT, gets the signed
    /// PSBT back, finalises and broadcasts. No QR round-trip.
    case hardwareBLE
    /// Air-gapped hardware wallet. Maknoon builds the unsigned PSBT
    /// and the user moves it to the device via QR (or microSD on
    /// SeedSigner); the device signs offline; the signed PSBT comes
    /// back via QR. Maknoon finalises and broadcasts.
    case airgappedPSBT
}

/// A device the user has registered with Maknoon. Identified by
/// `serial`, which is a stable per-device string sourced from the
/// vendor (YubiKey serial number, Ledger BLE peripheral identifier,
/// Trezor device_id from Features).
struct RegisteredDevice: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: DeviceKind
    /// Stable identifier reported by the vendor. We use this to
    /// confirm "this is the same physical device" on every
    /// reconnect. Display in the UI is truncated; full string is
    /// shown in the device detail view.
    let serial: String
    var label: String
    let registeredAt: Date

    /// iOS-stable BLE peripheral identifier captured at pair time.
    /// Used as a hard filter on subsequent connect attempts so the
    /// app cannot accidentally talk to a different physical Ledger /
    /// Trezor the user also has paired with this iPhone. Nil only
    /// for devices registered before this field existed; the next
    /// successful connect upgrades them in place.
    var peripheralUUID: UUID?

    /// Per-capability promotion record. Each entry is a snapshot of
    /// what the user opted in to. Removing an entry triggers an
    /// explicit "remove this device from Identity / Bitcoin / etc."
    /// UX, the device remains registered (and can be re-promoted).
    var promotions: Promotions

    struct Promotions: Codable, Hashable, Sendable {
        var identity: IdentityPromotion?
        var bitcoinWalletIds: [UUID]    // BitcoinWalletStore wallet ids
        var ethereumWalletIds: [UUID]   // EthereumWalletStore wallet ids
        var solanaWalletIds: [UUID]     // SolanaWalletStore wallet ids
        var tronWalletIds: [UUID]       // TronWalletStore wallet ids

        static let empty = Promotions(
            identity: nil,
            bitcoinWalletIds: [],
            ethereumWalletIds: [],
            solanaWalletIds: [],
            tronWalletIds: []
        )

        // Tolerant decoder so on-disk registry JSON written before the
        // new chain fields existed still loads. Missing-key fields
        // decode to an empty `[UUID]`.
        init(
            identity: IdentityPromotion?,
            bitcoinWalletIds: [UUID],
            ethereumWalletIds: [UUID],
            solanaWalletIds: [UUID] = [],
            tronWalletIds: [UUID] = []
        ) {
            self.identity = identity
            self.bitcoinWalletIds = bitcoinWalletIds
            self.ethereumWalletIds = ethereumWalletIds
            self.solanaWalletIds = solanaWalletIds
            self.tronWalletIds = tronWalletIds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.identity = try c.decodeIfPresent(IdentityPromotion.self, forKey: .identity)
            self.bitcoinWalletIds = try c.decodeIfPresent([UUID].self, forKey: .bitcoinWalletIds) ?? []
            self.ethereumWalletIds = try c.decodeIfPresent([UUID].self, forKey: .ethereumWalletIds) ?? []
            self.solanaWalletIds = try c.decodeIfPresent([UUID].self, forKey: .solanaWalletIds) ?? []
            self.tronWalletIds = try c.decodeIfPresent([UUID].self, forKey: .tronWalletIds) ?? []
        }
    }

    struct IdentityPromotion: Codable, Hashable, Sendable {
        /// FIDO2 credential id (hex-encoded) the device returned when
        /// we enrolled it for the hmac-secret wrap. Lets us pick the
        /// right credential at unlock time if the device holds more
        /// than one.
        let credentialIdHex: String
        let enrolledAt: Date
        /// Wrap-derivation protocol version. 1 = raw-signature
        /// (broken: FIDO2 signature counter drifts so unlock can never
        /// reproduce the enrollment-time signature). 2 = FIDO2
        /// hmac-secret extension (deterministic per credential+salt).
        /// Nil on records written before this field existed; the
        /// loadWrapped path treats nil as v1 and surfaces a re-enroll
        /// prompt.
        let wrapProtocolVersion: Int?

        init(credentialIdHex: String, enrolledAt: Date, wrapProtocolVersion: Int? = 2) {
            self.credentialIdHex = credentialIdHex
            self.enrolledAt = enrolledAt
            self.wrapProtocolVersion = wrapProtocolVersion
        }
    }

    init(
        id: UUID = UUID(),
        kind: DeviceKind,
        serial: String,
        label: String,
        registeredAt: Date = .init(),
        promotions: Promotions = .empty,
        peripheralUUID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.serial = serial
        self.label = label
        self.registeredAt = registeredAt
        self.promotions = promotions
        self.peripheralUUID = peripheralUUID
    }

    /// Short display of the serial for list rows.
    var serialDisplay: String {
        if serial.count <= 12 { return serial }
        return "\(serial.prefix(6))…\(serial.suffix(4))"
    }
}
