// Trezor BLE client. Connects over CoreBluetooth and speaks the
// Trezor Host Protocol (THP v2) through the `trezor-core` Rust crate.
//
// Unlike LedgerBLE (which frames APDUs in Swift), the Trezor wire
// protocol — packet framing, channel allocation, the Noise XX
// handshake, the AES-256-GCM session, ABP/ACK — all lives in Rust
// (`trezor-core`). Swift owns ONLY the raw BLE byte pipe: it writes
// one report to the write characteristic and hands each notify report
// back, via the `TrezorTransport` foreign-callback the Rust client
// drives.
//
// Wire reference (github.com/trezor/trezor-firmware, docs/common/thp):
//
//   Service UUID:         8c000001-a59b-4d58-a9ad-073df69fa1b1
//   Write characteristic: 8c000002-a59b-4d58-a9ad-073df69fa1b1
//   Notify characteristic: 8c000003-a59b-4d58-a9ad-073df69fa1b1
//   BLE packet size: 244 bytes.
//
// `establishPairedSession()` runs CodeEntry pairing (prompting for the
// 6-digit code) and persists a reconnection credential. `pair()`,
// `signMessage()`, and `identifyDevice()` then reconnect with that
// credential (no code re-entry) and return the attestor pubkey, an
// EIP-191 signature, or the stable `device_id` respectively. The
// read-only `thpProbe()` (no pairing) remains for diagnostics.
//
// (Earlier note, retained:) the per-chain seed methods stay
// `notImplemented` until the THP pairing + session-message layers
// land; the protocol's default impls cover the rest.

import CoreBluetooth
import Foundation

private nonisolated(unsafe) let trezorServiceUUID = CBUUID(string: "8c000001-a59b-4d58-a9ad-073df69fa1b1")
private nonisolated(unsafe) let trezorWriteUUID = CBUUID(string: "8c000002-a59b-4d58-a9ad-073df69fa1b1")
private nonisolated(unsafe) let trezorNotifyUUID = CBUUID(string: "8c000003-a59b-4d58-a9ad-073df69fa1b1")

final class TrezorBLE: NSObject, HardwareWallet, @unchecked Sendable {
    var kind: HardwareWalletKind { .trezor }

    var currentBLEPeripheralUUID: UUID? { peripheral?.identifier }

    /// When set, `ensureConnected` hard-filters scan + retrieve-
    /// connected results to this specific peripheral so we never
    /// connect to a different Trezor the user also owns.
    var targetPeripheralUUID: UUID?

    /// Which wallet seed-deriving ops target: the standard wallet, or a
    /// passphrase (hidden) wallet. Set by a discovery/add flow before
    /// the ops run; defaults to the standard wallet.
    var pendingPassphrase: PassphraseSpec = .standard

    /// Map a model-layer `PassphraseChoice` onto the UniFFI
    /// `PassphraseSpec` the Rust client wants, keeping the TrezorCore
    /// type out of the SwiftUI / model layer. Call this before a
    /// discovery sweep or a signing op so the right THP session is
    /// opened.
    func applyPassphraseMode(_ choice: PassphraseChoice) {
        switch choice {
        case .standard:            pendingPassphrase = .standard
        case .onDevice:            pendingPassphrase = .onDevice
        case .hostTyped(let pass): pendingPassphrase = .host(passphrase: pass)
        }
    }

    /// Custom BIP32 path for the next seed-deriving op(s); nil = the
    /// chain's standard path from `account`. Set by add/discover/sign
    /// flows for custom- or alternative-path wallets.
    var pendingDerivationPath: String?

    func setDerivationPathOverride(_ path: String?) {
        pendingDerivationPath = path
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var poweredOnContinuation: CheckedContinuation<Void, Error>?
    private var connectedContinuation: CheckedContinuation<Void, Error>?
    private var servicesReadyContinuation: CheckedContinuation<Void, Error>?

    // Inbound notify reports buffered for `readChunk()`. The Rust THP
    // layer reassembles these into messages, so Swift never inspects
    // them — one notify == one report in the queue.
    private var inbox: [Data] = []
    private var readContinuation: CheckedContinuation<Data, Error>?

    // Lazily-built Rust client, reset on disconnect/teardown.
    private var client: TrezorClient?

    private func trezorClient() -> TrezorClient {
        if let c = client { return c }
        let c = TrezorClient(transport: TrezorTransportAdapter(parent: self))
        client = c
        return c
    }

    // MARK: -- connection

    /// Scan, connect, discover the THP service, and subscribe to the
    /// notify characteristic. Mirrors LedgerBLE's machinery; the
    /// `state == .connected` check forces a clean reconnect when iOS
    /// has quietly dropped a stale link.
    private func ensureConnected() async throws {
        if let p = peripheral, p.state == .connected, writeChar != nil, notifyChar != nil {
            return
        }
        central?.stopScan()
        if let p = peripheral, let c = central {
            c.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        connectedContinuation = nil
        servicesReadyContinuation = nil
        inbox.removeAll()

        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if let central, central.state == .poweredOn {
                cont.resume()
            } else {
                self.poweredOnContinuation = cont
            }
        }

        // Reconnect directly to an OS-known peripheral if possible,
        // hard-filtered to `targetPeripheralUUID` when set.
        let knownPeripheral: CBPeripheral? = {
            guard let central else { return nil }
            let known = central.retrieveConnectedPeripherals(withServices: [trezorServiceUUID])
            if let target = targetPeripheralUUID {
                return known.first(where: { $0.identifier == target })
            }
            return known.first
        }()
        var skipScan = false
        if let central, let knownPeripheral {
            self.peripheral = knownPeripheral
            knownPeripheral.delegate = self
            try await withTimeout(seconds: 15, label: "Trezor BLE direct-connect") {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.connectedContinuation = cont
                    if knownPeripheral.state == .connected {
                        cont.resume()
                        self.connectedContinuation = nil
                    } else {
                        central.connect(knownPeripheral, options: nil)
                    }
                }
            }
            skipScan = true
        }

        if !skipScan {
            try await withTimeout(seconds: 25, label: "Trezor BLE scan") {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.connectedContinuation = cont
                    self.central?.scanForPeripherals(withServices: [trezorServiceUUID], options: nil)
                }
            }
        }

        try await withTimeout(seconds: 15, label: "Trezor BLE service discovery") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.servicesReadyContinuation = cont
                self.peripheral?.discoverServices([trezorServiceUUID])
            }
        }
    }

    /// Race an async op against a deadline; on timeout, reset BLE
    /// state and fail any waiting continuation. Same shape as
    /// LedgerBLE.withTimeout.
    private func withTimeout<T>(seconds: Double, label: String, op: () async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Date() >= deadline {
                self?.tripTimeout(label: label, seconds: seconds)
            }
        }
        defer { watchdog.cancel() }
        return try await op()
    }

    private func tripTimeout(label: String, seconds: Double) {
        let msg = "\(label) timed out after \(Int(seconds))s. Make sure your Trezor is unlocked, Bluetooth is on, and the device is in range."
        let err = HardwareWalletError.transport(msg)
        readContinuation?.resume(throwing: err)
        readContinuation = nil
        connectedContinuation?.resume(throwing: err)
        connectedContinuation = nil
        servicesReadyContinuation?.resume(throwing: err)
        servicesReadyContinuation = nil
        central?.stopScan()
        if let p = peripheral, let c = central {
            c.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
    }

    /// Reference-counted session pin. While > 0, `resetSession` is a
    /// no-op so the BLE connection AND the cached Rust client (which
    /// holds the pinned, paired+seeded THP session) survive across a
    /// compound flow (identity enroll, wallet discovery scanning many
    /// accounts, multi-step send). Without it every op would tear down
    /// and reconnect — slow, and the device flags TRANSPORT_BUSY on the
    /// rapid channel churn.
    private var sessionPinCount = 0

    func beginSession() {
        sessionPinCount += 1
    }

    func endSession() {
        sessionPinCount = max(0, sessionPinCount - 1)
        if sessionPinCount == 0 {
            forceReset()
        }
    }

    /// Tear down the BLE session unless a pin is held. Called via
    /// `defer` after every op; a no-op mid-pin so the connection +
    /// Rust session are reused by the next op.
    func resetSession() {
        if sessionPinCount > 0 { return }
        forceReset()
    }

    /// Unconditional teardown. Dropping `client` releases the Rust
    /// TrezorClient and its pinned connection; the next call rebuilds
    /// against a fresh connection.
    private func forceReset() {
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        readContinuation?.resume(throwing: HardwareWalletError.transport("Trezor session reset"))
        readContinuation = nil
        inbox.removeAll()
        writeChar = nil
        notifyChar = nil
        peripheral = nil
        client = nil
        poweredOnContinuation?.resume(throwing: HardwareWalletError.transport("Trezor session reset"))
        poweredOnContinuation = nil
        connectedContinuation?.resume(throwing: HardwareWalletError.transport("Trezor session reset"))
        connectedContinuation = nil
        servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("Trezor session reset"))
        servicesReadyContinuation = nil
    }

    // MARK: -- raw transport (driven by the Rust client)

    /// Write one THP report to the device's write characteristic.
    fileprivate func transportWrite(_ data: Data) async throws {
        try await ensureConnected()
        guard let writeChar, let peripheral else {
            throw HardwareWalletError.transport("Not connected to Trezor over BLE")
        }
        peripheral.writeValue(data, for: writeChar, type: .withResponse)
    }

    /// Await and return the next THP report from the notify
    /// characteristic (or a buffered one).
    fileprivate func transportRead() async throws -> Data {
        if !inbox.isEmpty {
            return inbox.removeFirst()
        }
        return try await withTimeout(seconds: 30, label: "Trezor BLE read") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                if !self.inbox.isEmpty {
                    cont.resume(returning: self.inbox.removeFirst())
                } else {
                    self.readContinuation = cont
                }
            }
        }
    }

    // MARK: -- HardwareWallet conformance

    /// Load the persisted credential + host key, or throw a clear
    /// "register first" error.
    private func credentialAndHostKey() throws -> (credential: Data, hostKey: Data) {
        guard let credential = try TrezorCredentialStore.loadCredential() else {
            throw HardwareWalletError.transport(
                "Register your Trezor first so Maknoon has a pairing credential."
            )
        }
        return (credential, try TrezorCredentialStore.hostStaticKey())
    }

    /// Retry an op that hits THP `TRANSPORT_BUSY` — the device still
    /// tearing down a prior channel on a rapid reconnect. Per the spec
    /// we drop the link, back off, and retry (bounded). A stopgap until
    /// session pinning removes the per-op reconnect churn entirely.
    private func withBusyRetry<T>(_ op: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await op()
            } catch let error as TrezorError {
                guard case .TransportBusy = error, attempt < 3 else { throw error }
                attempt += 1
                resetSession()
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
    }

    /// Returns the device's stable `device_id` (the same value
    /// registration stored as the serial), so every device-match check
    /// recognises this Trezor. Reconnects with the stored credential —
    /// no code entry — so the device must already be registered/paired.
    func identifyDevice() async throws -> String {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().identifyPaired(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential
            )
        }
    }

    /// Full THP CodeEntry pairing: connect, handshake, pair (prompting
    /// for the on-device code via `codeProvider`), reach
    /// ENCRYPTED_TRANSPORT, and read `Features`. Returns the device's
    /// real `device_id` (a stable serial), the reconnection credential,
    /// and the BLE peripheral UUID. Pass a non-nil `storedCredential`
    /// to skip on-device pairing on a known device.
    func establishPairedSession(
        hostStaticPriv: Data,
        codeProvider: PairingCodeProvider,
        storedCredential: Data?
    ) async throws -> (serial: String, credential: Data, peripheralUUID: UUID?) {
        defer { resetSession() }
        try await ensureConnected()
        let result = try await trezorClient().establishPairedSession(
            hostStaticPriv: hostStaticPriv,
            hostName: "Maknoon",
            appName: "Maknoon iOS",
            storedCredential: storedCredential,
            codeProvider: codeProvider
        )
        // Read the peripheral id before the deferred resetSession nils it.
        return (result.deviceId, result.credential, peripheral?.identifier)
    }

    /// Identity-sandwich attestor secp256k1 pubkey. Reconnects with the
    /// stored credential (no code entry) and reads the Ethereum public
    /// key at m/44'/60'/0'/0/0.
    func pair() async throws -> Data {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().getAttestorPubkey(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential
            )
        }
    }

    /// Deterministic EIP-191 signature (R||S) with the attestor key,
    /// for identity-sandwich attestation + the AES-GCM wrap challenge.
    func signMessage(_ message: Data) async throws -> Data {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().signMessageEth(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                message: message
            )
        }
    }

    /// EIP-55 address for BIP44 account `account`, on the current
    /// `pendingPassphrase` wallet (standard or hidden). Reconnects with
    /// the stored credential; within a pinned discovery the seeded
    /// session is reused across accounts.
    func getEthereumAddress(account: UInt32) async throws -> String {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().getEthereumAddress(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                account: account,
                path: path
            )
        }
    }

    /// Sign an EIP-1559 transaction for BIP44 account `account` on the
    /// current `pendingPassphrase` wallet (standard or hidden). The
    /// `envelope` is the same 0x02-prefixed unsigned RLP the Ledger path
    /// builds; the Rust client decodes it into Trezor's structured
    /// fields, drives the on-device confirmation, and returns the
    /// parity-bit V plus 32-byte R / S. `erc20Descriptor` is Ledger-CAL
    /// specific and ignored: Trezor renders token transfers from its own
    /// token definitions.
    func signEthereumTransaction(
        envelope: Data,
        account: UInt32,
        erc20Descriptor: Data?
    ) async throws -> (v: UInt8, r: Data, s: Data) {
        defer { resetSession() }
        _ = erc20Descriptor
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        let sig = try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().signEthereumTx(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                envelope: envelope,
                account: account,
                path: path
            )
        }
        return (sig.v, sig.r, sig.s)
    }

    /// BIP84 account-level xpub for the current `pendingPassphrase`
    /// wallet, used to build a watch-only BDK descriptor host-side.
    /// Within a pinned discovery the seeded session is reused across
    /// accounts.
    func getBitcoinAccountXpub(account: UInt32, networkCoinType: UInt32) async throws -> String {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().getBitcoinAccountXpub(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                account: account,
                networkCoinType: networkCoinType,
                path: path
            )
        }
    }

    /// Hex-encoded 4-byte BIP32 master root fingerprint for the current
    /// `pendingPassphrase` wallet. The Trezor reports it independent of
    /// coin type, so `networkCoinType` is unused here; it stays in the
    /// signature to satisfy the vendor-agnostic protocol.
    func getBitcoinMasterFingerprint(networkCoinType: UInt32) async throws -> String {
        defer { resetSession() }
        _ = networkCoinType
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let fp = try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().getBitcoinMasterFingerprint(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase
            )
        }
        return fp.map { String(format: "%02x", $0) }.joined()
    }

    /// Base58 ed25519 address for SLIP-0010 account `account` on the
    /// current `pendingPassphrase` wallet. Within a pinned discovery
    /// the seeded session is reused across accounts.
    func getSolanaAddress(account: UInt32) async throws -> String {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().getSolanaAddress(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                account: account,
                path: path
            )
        }
    }

    /// Sign a serialized Solana message for the current
    /// `pendingPassphrase` wallet; returns the 64-byte ed25519
    /// signature the caller prepends to the transaction.
    func signSolanaTransaction(unsignedTx: Data, account: UInt32) async throws -> Data {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().signSolanaTx(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                unsignedTx: unsignedTx,
                account: account,
                path: path
            )
        }
    }

    /// Base58Check `T...` Tron address for the current
    /// `pendingPassphrase` wallet.
    func getTronAddress(account: UInt32) async throws -> String {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().getTronAddress(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                account: account,
                path: path
            )
        }
    }

    /// Sign a Tron transaction for the current `pendingPassphrase`
    /// wallet. `rawTxProto` is the network-built `raw_data`; the Rust
    /// client decodes it, drives the structured SignTx exchange, and
    /// returns the recoverable signature split into (v, r, s), which the
    /// caller reassembles into r||s||v.
    func signTronTransaction(
        rawTxProto: Data,
        account: UInt32
    ) async throws -> (v: UInt8, r: Data, s: Data) {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        let sig = try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().signTronTx(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                rawTxProto: rawTxProto,
                account: account,
                path: path
            )
        }
        return (sig.v, sig.r, sig.s)
    }

    /// Sign a BIP84 PSBT for the current `pendingPassphrase` wallet.
    /// Drives Trezor's `SignTx` streaming exchange in Rust and returns
    /// the signed PSBT base64 with `partial_sigs` merged in, matching
    /// the Ledger contract so the BDK finalize + broadcast path is
    /// reused unchanged. `fingerprintHex` / `accountXpub` / `account`
    /// are accepted for that contract parity; the spend paths come from
    /// the PSBT itself.
    func signBitcoinPSBT(
        unsignedBase64: String,
        fingerprintHex: String,
        accountXpub: String,
        account: UInt32,
        coinType: UInt32
    ) async throws -> String {
        defer { resetSession() }
        let creds = try credentialAndHostKey()
        let passphrase = pendingPassphrase
        let path = pendingDerivationPath
        return try await withBusyRetry {
            try await ensureConnected()
            return try await trezorClient().signPsbt(
                hostStaticPriv: creds.hostKey,
                credential: creds.credential,
                passphrase: passphrase,
                psbtBase64: unsignedBase64,
                fingerprintHex: fingerprintHex,
                accountXpub: accountXpub,
                account: account,
                coinType: coinType,
                path: path
            )
        }
    }
}

// MARK: -- TrezorTransport adapter
//
// Bridges the Rust client's foreign-callback transport into the BLE
// byte pipe. The client calls `writeChunk`/`readChunk` for each THP
// report; we route them to TrezorBLE.

private final class TrezorTransportAdapter: TrezorTransport, @unchecked Sendable {
    private weak var parent: TrezorBLE?

    init(parent: TrezorBLE) { self.parent = parent }

    func writeChunk(data: Data) async throws {
        guard let parent else {
            throw TrezorTransportError.Disconnected(reason: "TrezorBLE deallocated mid-exchange")
        }
        do {
            try await parent.transportWrite(data)
        } catch let hwError as HardwareWalletError {
            throw TrezorTransportError.Io(reason: hwError.description)
        } catch {
            throw TrezorTransportError.Io(reason: error.localizedDescription)
        }
    }

    func readChunk() async throws -> Data {
        guard let parent else {
            throw TrezorTransportError.Disconnected(reason: "TrezorBLE deallocated mid-exchange")
        }
        do {
            return try await parent.transportRead()
        } catch let hwError as HardwareWalletError {
            throw TrezorTransportError.Io(reason: hwError.description)
        } catch {
            throw TrezorTransportError.Io(reason: error.localizedDescription)
        }
    }
}

// MARK: -- CB delegates

extension TrezorBLE: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            poweredOnContinuation?.resume()
            poweredOnContinuation = nil
        case .poweredOff:
            poweredOnContinuation?.resume(throwing: HardwareWalletError.transport("Bluetooth is off"))
            poweredOnContinuation = nil
        case .unauthorized:
            poweredOnContinuation?.resume(throwing: HardwareWalletError.transport("Bluetooth permission denied"))
            poweredOnContinuation = nil
        case .unsupported:
            poweredOnContinuation?.resume(throwing: HardwareWalletError.transport("BLE unsupported"))
            poweredOnContinuation = nil
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if let target = targetPeripheralUUID, peripheral.identifier != target {
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedContinuation?.resume()
        connectedContinuation = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let reason = error?.localizedDescription ?? "unknown"
        connectedContinuation?.resume(throwing: HardwareWalletError.transport("connect failed: \(reason)"))
        connectedContinuation = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let reason = error?.localizedDescription ?? "device disconnected"
        let err = HardwareWalletError.transport("Trezor disconnected: \(reason)")
        readContinuation?.resume(throwing: err)
        readContinuation = nil
        connectedContinuation?.resume(throwing: err)
        connectedContinuation = nil
        servicesReadyContinuation?.resume(throwing: err)
        servicesReadyContinuation = nil
        writeChar = nil
        notifyChar = nil
        self.peripheral = nil
    }
}

extension TrezorBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("Trezor service discovery failed"))
            servicesReadyContinuation = nil
            return
        }
        for svc in services where svc.uuid == trezorServiceUUID {
            peripheral.discoverCharacteristics([trezorWriteUUID, trezorNotifyUUID], for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let chars = service.characteristics ?? []
        guard !chars.isEmpty else {
            servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("Trezor characteristic discovery failed"))
            servicesReadyContinuation = nil
            return
        }
        writeChar = chars.first { $0.uuid == trezorWriteUUID }
        notifyChar = chars.first { $0.uuid == trezorNotifyUUID }
        guard let notifyChar, writeChar != nil else {
            servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("Trezor write/notify characteristic missing"))
            servicesReadyContinuation = nil
            return
        }
        peripheral.setNotifyValue(true, for: notifyChar)
        servicesReadyContinuation?.resume()
        servicesReadyContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == trezorNotifyUUID, let data = characteristic.value else { return }
        if let cont = readContinuation {
            readContinuation = nil
            cont.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }
}
