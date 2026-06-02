// Ledger Nano X BLE client. Connects over CoreBluetooth, framed APDUs
// per Ledger's published transport spec, talks to the Ethereum app
// for GET_PUBLIC_KEY and SIGN_PERSONAL_MESSAGE.
//
// Wire reference (Ledger public docs + ledger-live-mobile):
//
//   Service UUID:        13d63400-2c97-0004-0000-4c6564676572
//   Write characteristic: 13d63400-2c97-0004-0002-4c6564676572
//   Notify characteristic: 13d63400-2c97-0004-0001-4c6564676572
//
// Each BLE packet:
//
//   byte 0       TAG (0x05 for APDU)
//   bytes 1-2    packet index (big endian)
//   bytes 3-4    total APDU length, only in the first packet
//   bytes 5+     APDU bytes (chunked across packets)
//
// Ethereum app APDUs used here:
//
//   GET_PUBLIC_KEY:        CLA=E0 INS=02 P1=00 P2=00
//   SIGN_PERSONAL_MESSAGE: CLA=E0 INS=08 P1=00 P2=00
//
// Data layouts (5-level BIP32 path m/44'/60'/0'/0/0):
//
//   Path bytes: 05 8000002C 8000003C 80000000 00000000 00000000
//
// SIGN_PERSONAL_MESSAGE data:
//   path bytes || u32 message-length big-endian || message bytes
//
// Hash convention: SIGN_PERSONAL_MESSAGE prefixes the message with
// "\x19Ethereum Signed Message:\n<L>" and runs keccak256 on that. The
// server's `ledger-secp256k1` hardware-attestation check must match
// this convention to verify the returned signature.
//
// On-device confirmation: every SIGN_PERSONAL_MESSAGE call shows the
// message bytes on the Ledger screen and waits for two button presses.
// GET_PUBLIC_KEY can be no-prompt (P1=00) or prompt-confirm (P1=01).

import CoreBluetooth
import Foundation
import WalletCore

private nonisolated(unsafe) let ledgerServiceUUID = CBUUID(string: "13d63400-2c97-0004-0000-4c6564676572")
private nonisolated(unsafe) let ledgerWriteUUID   = CBUUID(string: "13d63400-2c97-0004-0002-4c6564676572")
private nonisolated(unsafe) let ledgerNotifyUUID  = CBUUID(string: "13d63400-2c97-0004-0001-4c6564676572")

// Standard Battery Service + Battery Level. Used purely as a
// keep-alive target: periodic reads of the battery level
// characteristic generate BLE LL traffic that resets the Ledger's
// supervision-timeout countdown while the user is reading the
// on-device confirmation screen. It's on a completely separate
// GATT service from the APDU pipe, so it can't interfere with or
// crash the Bitcoin app.
private nonisolated(unsafe) let batteryServiceUUID = CBUUID(string: "180F")
private nonisolated(unsafe) let batteryLevelUUID   = CBUUID(string: "2A19")

private let bleApduTag: UInt8 = 0x05

final class LedgerBLE: NSObject, HardwareWallet, @unchecked Sendable {
    var kind: HardwareWalletKind { .ledger }

    /// iOS-stable BLE identifier for the currently-connected peripheral.
    /// Captured at pair time and stored on `RegisteredDevice.peripheralUUID`
    /// so subsequent reconnects scan-filter to this specific device.
    var currentBLEPeripheralUUID: UUID? { peripheral?.identifier }

    /// When non-nil, `ensureConnected` filters scan + retrieve-connected
    /// results to ONLY this peripheral. Set by the caller before
    /// `connect()` to bind to a specific physical Ledger.
    var targetPeripheralUUID: UUID?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    // Battery Level char on the standard Battery Service. Best-effort
    // for keep-alive only: if for any reason the device doesn't
    // expose it, the heartbeat just no-ops and we fall back to the
    // baseline ~600-800ms supervision-timeout idle threshold.
    private var batteryLevelChar: CBCharacteristic?

    // Reassembly state for a single APDU response.
    private var pendingAPDU: PendingAPDU?
    private struct PendingAPDU {
        var totalLength: Int = -1
        var buffer: Data = Data()
        var continuation: CheckedContinuation<Data, Error>?
    }

    // Continuations for the various phases.
    private var poweredOnContinuation: CheckedContinuation<Void, Error>?
    private var connectedContinuation: CheckedContinuation<Void, Error>?
    private var servicesReadyContinuation: CheckedContinuation<Void, Error>?

    /// Reference-counted session pin. While > 0, the trailing
    /// `defer { resetSession() }` in every public method is a no-op,
    /// so a caller doing multi-step operations (identifyDevice ->
    /// getMasterFingerprint -> getAccountXpub xN for Discover) keeps
    /// the same BLE connection across them. Without this, every
    /// method would tear down, the next call would re-scan +
    /// reconnect, and the Ledger drops the link after a few rounds.
    private var sessionPinCount: Int = 0

    /// One-time setup: scan, connect, discover, set notify on the
    /// notify characteristic. Returns when the GATT plumbing is ready
    /// for APDU exchange.
    ///
    /// Crucially, this checks `peripheral.state == .connected` instead
    /// of just "we have cached characteristics." iOS can quietly drop
    /// the BLE link (Ledger's idle timeout, RF blip, etc.) between two
    /// of our calls; if we trust stale `writeChar`/`notifyChar`
    /// references the subsequent write goes into the void and we hang
    /// until iOS flushes the disconnect event. The state check forces
    /// a clean reconnect when the cached state is no longer live.
    private func ensureConnected() async throws {
        if let p = peripheral, p.state == .connected, writeChar != nil, notifyChar != nil {
            return
        }
        // Tear down any stale cached state before rebuilding. Stop
        // any in-flight scan from a previous abandoned attempt so
        // the new scan starts cleanly.
        central?.stopScan()
        if let p = peripheral, let c = central {
            c.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        batteryLevelChar = nil
        // Drop any stale continuations so the next throw-on-timeout
        // can install fresh ones without racing the old ones.
        connectedContinuation = nil
        servicesReadyContinuation = nil

        // Power on central.
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

        // First check whether iOS already holds a connection to a
        // Ledger from a previous session. This catches the case
        // where the OS still has the device bonded but it's no
        // longer actively advertising (so a plain scan would miss
        // it). retrieveConnectedPeripherals also includes devices
        // CONNECTED TO OTHER PROCESSES (e.g. Ledger Live in the
        // background), which we can connect to directly.
        var skipScan = false
        // If `targetPeripheralUUID` is set, hard-filter the
        // OS-known peripherals to that specific identifier so we
        // never accidentally connect to a different Ledger the user
        // also has paired. With no target set (eg. the
        // RegisterDeviceSheet pair flow before we know which device
        // is which), fall back to the first matching peripheral
        // as before.
        let knownPeripheral: CBPeripheral? = {
            guard let central else { return nil }
            let known = central.retrieveConnectedPeripherals(withServices: [ledgerServiceUUID])
            if let target = targetPeripheralUUID {
                return known.first(where: { $0.identifier == target })
            }
            return known.first
        }()
        if let central, let knownPeripheral {
            LogStore.shared.info("ledger.ble", "found known-connected peripheral \(knownPeripheral.identifier.uuidString), connecting directly")
            self.peripheral = knownPeripheral
            knownPeripheral.delegate = self
            try await withTimeout(seconds: 15, label: "Ledger BLE direct-connect") {
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

        // Fall back to scanning if no known peripheral. Time-bound
        // at 25 seconds so we fail fast with a clear "didn't see
        // your Ledger" message if the device is locked, out of
        // range, or its BLE radio is off.
        if !skipScan {
            try await withTimeout(seconds: 25, label: "Ledger BLE scan") {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.connectedContinuation = cont
                    self.central?.scanForPeripherals(withServices: [ledgerServiceUUID], options: nil)
                }
            }
        }

        // Discover characteristics + subscribe to notify. Time-bound
        // so GATT discovery glitches don't hang the user.
        try await withTimeout(seconds: 15, label: "Ledger BLE service discovery") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.servicesReadyContinuation = cont
                // Discover both the Ledger APDU service and the
                // standard Battery service. The latter is used
                // purely as the keep-alive heartbeat target during
                // long APDU waits (user-confirmation screens).
                self.peripheral?.discoverServices([ledgerServiceUUID, batteryServiceUUID])
            }
        }
    }

    /// Race an async op against a timer; whichever finishes first
    /// wins, and on timeout we throw a clear transport error AND
    /// tear down the BLE state so the next attempt doesn't inherit
    /// half-broken continuations. Without this iOS will sit waiting
    /// on its own internal timeouts (often 30+ seconds with vague
    /// "connection has timed out unexpectedly" errors) and leave
    /// state in a way that the next user retry also times out.
    ///
    /// We don't use TaskGroup here because CBPeripheral and
    /// CBCharacteristic aren't Sendable, and capturing them in
    /// @Sendable closures triggers strict-concurrency errors. The
    /// timer Task only deals with TimeInterval + a cancellation
    /// flag, not BLE types, so it's straightforward.
    private func withTimeout<T>(seconds: Double, label: String, op: () async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(seconds)
        // Spin up a watchdog that resets BLE state at the deadline.
        // The reset trips any waiting continuation (the scan, the
        // discovery, the APDU response) with a "BLE state reset"
        // error, which propagates out of the awaited op() below.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Date() >= deadline {
                self?.tripTimeout(label: label, seconds: seconds)
            }
        }
        defer { watchdog.cancel() }
        return try await op()
    }

    /// Called by the watchdog when a timeout fires. Re-fails every
    /// waiting continuation with a clear timeout message so the
    /// awaited op() in withTimeout throws.
    private func tripTimeout(label: String, seconds: Double) {
        let msg = "\(label) timed out after \(Int(seconds))s. Make sure your Ledger is awake (press a button), Bluetooth is on, and the Bitcoin app is open."
        if let pa = pendingAPDU?.continuation {
            pa.resume(throwing: HardwareWalletError.transport(msg))
            pendingAPDU = nil
        }
        if let cc = connectedContinuation {
            cc.resume(throwing: HardwareWalletError.transport(msg))
            connectedContinuation = nil
        }
        if let sr = servicesReadyContinuation {
            sr.resume(throwing: HardwareWalletError.transport(msg))
            servicesReadyContinuation = nil
        }
        central?.stopScan()
        if let p = peripheral, let c = central {
            c.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        batteryLevelChar = nil
    }

    /// Hard-reset BLE state so the next call to `ensureConnected`
    /// starts from scratch. Called on every timeout path so a
    /// half-finished scan/connect doesn't pollute the next attempt.
    private func resetBLEState() {
        central?.stopScan()
        if let p = peripheral, let c = central {
            c.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        batteryLevelChar = nil
        if let pa = pendingAPDU?.continuation {
            pa.resume(throwing: HardwareWalletError.transport("BLE state reset"))
        }
        pendingAPDU = nil
        if let cc = connectedContinuation {
            cc.resume(throwing: HardwareWalletError.transport("BLE state reset"))
        }
        connectedContinuation = nil
        if let sr = servicesReadyContinuation {
            sr.resume(throwing: HardwareWalletError.transport("BLE state reset"))
        }
        servicesReadyContinuation = nil
    }

    /// Send a complete APDU (header + Lc + data + Le) and await the
    /// reassembled response (without SW1 SW2 status bytes — caller
    /// gets the data and the status word separately).
    ///
    /// Pre-call we clear any stale `pendingAPDU` so a leftover
    /// continuation from a previous aborted call cannot get
    /// double-resumed when our response lands. The
    /// `didDisconnectPeripheral` handler and the
    /// `didUpdateValueFor` snapshot-clear-then-resume pattern are
    /// the other two defenses against the crash the user saw.
    private func sendAPDU(_ apdu: Data) async throws -> (data: Data, sw: UInt16) {
        try await ensureConnected()
        guard let writeChar, let peripheral else {
            throw HardwareWalletError.transport("Not connected to Ledger over BLE")
        }
        // If anything left pendingAPDU around from a prior aborted
        // call, fail it explicitly and drop it.
        if let stale = pendingAPDU?.continuation {
            stale.resume(throwing: HardwareWalletError.transport("Previous APDU was abandoned"))
        }
        pendingAPDU = nil

        // BLE keep-alive heartbeat. The Ledger's negotiated BLE
        // supervision timeout is ~600-800ms of LL silence; if we go
        // silent that long while the user reads + confirms on the
        // device, iOS drops the link and the device's SIGN_PSBT
        // state is lost.
        //
        // Counter: every 500ms (after a 400ms warmup) we read the
        // standard Battery Level characteristic. This is a GATT-layer
        // read on a completely separate service from the Ledger APDU
        // service, so it can't interfere with the protocol or crash
        // the Bitcoin app. The 400ms initial delay ensures fast
        // back-to-back protocol rounds (which usually complete in
        // <0.5s) never generate heartbeat traffic.
        //
        // Verified at this exact 400/500ms configuration: 200+
        // protocol rounds complete cleanly and the user gets ~17
        // seconds on the on-device confirmation screen before the
        // BLE link gives out. Tighter intervals interleave reads
        // with the inbound notify stream and cause CBError 6
        // mid-protocol disconnects.
        //
        // CoreBluetooth requires API calls on the queue the central
        // manager was created with (nil = main). @MainActor
        // isolation enforces that.
        let heartbeat = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                while !Task.isCancelled {
                    guard let self,
                          self.peripheral?.state == .connected,
                          let batChar = self.batteryLevelChar else { break }
                    self.peripheral?.readValue(for: batChar)
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                // Cancellation, parent op already completed.
            }
        }
        defer { heartbeat.cancel() }

        // APDU response timeout: 30 seconds. The Bitcoin app rarely
        // needs more than a few seconds per APDU, except for the
        // SIGN_PSBT on-device confirmation which the user can sit on
        // for a while before approving. 30s gives them a slow but
        // reasonable window to read the destination + amount and
        // press both buttons. If they're slower than that, they can
        // retry. Without an explicit timeout iOS BLE hangs can sit
        // forever (we've seen 90s+ in practice) before the OS gives
        // up with a vague disconnect message.
        let raw = try await withTimeout(seconds: 30, label: "Ledger APDU response") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.pendingAPDU = PendingAPDU(totalLength: -1, buffer: Data(), continuation: cont)
                // BLE chunk sizing: CoreBluetooth sometimes reports a
                // much larger maximumWriteValueLength than the Ledger
                // Nano X's BLE stack will actually accept on the air
                // (we've seen the OS say 512 while the device caps at
                // ~153 ATT MTU). Capping at 153 matches what works on
                // the macOS reference client and across protocol-
                // version-1 SIGN_PSBT runs in 200+ rounds.
                let reportedMtu = peripheral.maximumWriteValueLength(for: .withResponse) - 3
                let safeMtu = 153
                let mtu = max(20, min(safeMtu, reportedMtu))
                for packet in framedPackets(apdu: apdu, mtu: mtu) {
                    peripheral.writeValue(packet, for: writeChar, type: .withResponse)
                }
            }
        }

        guard raw.count >= 2 else {
            LogStore.shared.error("ledger.apdu", "response too short (\(raw.count) bytes)")
            throw HardwareWalletError.transport("APDU response too short (\(raw.count) bytes)")
        }
        let sw = (UInt16(raw[raw.count - 2]) << 8) | UInt16(raw[raw.count - 1])
        let data = raw.prefix(raw.count - 2)
        if sw != 0x9000 {
            LogStore.shared.warn("ledger.apdu", "non-9000 status: 0x\(String(sw, radix: 16))")
        }
        return (Data(data), sw)
    }

    /// Tear down the BLE session. Called on disconnect and from the
    /// UI when the user dismisses pairing so a stale `peripheral` /
    /// `writeChar` can't be reused by a subsequent attempt. When a
    /// session is pinned (beginSession was called by a caller doing
    /// multi-step work) this is a no-op; the pin holder owns the
    /// real teardown via endSession.
    func resetSession() {
        if sessionPinCount > 0 { return }
        forceResetSession()
    }

    /// Unconditional teardown. resetSession() defers to this when the
    /// pin count is zero. endSession() also calls this directly when
    /// the pin count drops to zero, so the connection actually closes
    /// at the end of a compound operation.
    private func forceResetSession() {
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        pendingAPDU?.continuation?.resume(throwing: HardwareWalletError.transport("Ledger session reset"))
        pendingAPDU = nil
        writeChar = nil
        notifyChar = nil
        batteryLevelChar = nil
        peripheral = nil
        // Drop the SDK clients too; next chain-specific call will
        // rebuild with a fresh adapter pointing at the new connection.
        bitcoinClient = nil
        solanaClient = nil
        ethereumClient = nil
        tronClient = nil
        poweredOnContinuation?.resume(throwing: HardwareWalletError.transport("Ledger session reset"))
        poweredOnContinuation = nil
        connectedContinuation?.resume(throwing: HardwareWalletError.transport("Ledger session reset"))
        connectedContinuation = nil
        servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("Ledger session reset"))
        servicesReadyContinuation = nil
    }

    func beginSession() {
        sessionPinCount += 1
    }

    func endSession() {
        sessionPinCount = max(0, sessionPinCount - 1)
        if sessionPinCount == 0 {
            forceResetSession()
        }
    }

    // MARK: -- HardwareWallet conformance

    /// Connect just long enough to learn the device's stable BLE
    /// peripheral identifier. We use that as the "serial" because
    /// Ledger does not expose its printed serial number through
    /// APDUs. The CoreBluetooth identifier is stable across
    /// reconnects on the same device and across iOS launches, which
    /// is what `RegisteredDevice.serial` needs.
    func identifyDevice() async throws -> String {
        // Tear down the BLE connection when this op finishes (success
        // or throw). Without this, iOS CoreBluetooth keeps the
        // peripheral handle cached; the next instance's
        // retrieveConnectedPeripherals returns the same peripheral
        // marked .connected, but the device-side state has drifted
        // (Ethereum app exited, device locked, etc.) and the next
        // APDU hangs into CBError code=6. resetSession is idempotent
        // and side-effect-safe to fire after a successful return.
        defer { resetSession() }
        try await ensureConnected()
        guard let peripheral else {
            throw HardwareWalletError.transport("Could not connect to Ledger over BLE")
        }
        return peripheral.identifier.uuidString
    }

    func pair() async throws -> Data {
        defer { resetSession() }
        try await ensureConnected()
        // Pairing uses the Ethereum app's GET_PUBLIC_KEY (no prompt)
        // for the device's stable secp256k1 pubkey. Wrapped to the
        // compressed form so the wire-format kind is consistent
        // across vendors.
        do {
            let addr = try await ethereumSDK().getAddressForAccount(account: 0, display: false)
            return compressSecp256k1Pubkey(Data(addr.pubkey))
        } catch {
            throw mapEthereumSDKError(error, command: "GET_PUBLIC_KEY (pair)")
        }
    }

    /// Ethereum app GET_PUBLIC_KEY at BIP44 path
    /// `m/44'/60'/<account>'/0/0`. Returns the EIP-55 checksummed
    /// address. Delegates to ledger-eth-core, which hand-rolls the
    /// APDU and the EIP-55 step in Rust so iOS / Android share the
    /// same implementation.
    func getEthereumAddress(account: UInt32) async throws -> String {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let addr = try await ethereumSDK().getAddressForAccount(account: account, display: false)
            return addr.address
        } catch {
            throw mapEthereumSDKError(error, command: "GET_PUBLIC_KEY")
        }
    }

    /// Ledger Ethereum app SIGN_TRANSACTION (CLA=0xE0 INS=0x04).
    /// Chunked: first APDU (P1=0x00) carries `pathLen || path ||
    /// initial_envelope_bytes`; subsequent APDUs (P1=0x80) carry the
    /// remaining envelope bytes. Last APDU's reply contains V/R/S.
    ///
    /// `envelope` is the EIP-1559 unsigned blob:
    ///   0x02 || rlp([chainId, nonce, ..., accessList])
    /// Returned V is 0 or 1 (parity bit); the caller assembles the
    /// signed transaction via `EthereumTxEncoder.signedEnvelope`.
    ///
    /// `erc20Descriptor`, when present, is a Ledger-signed CAL token
    /// blob (see `LedgerERC20Descriptors`). We provide it to the
    /// Ethereum app immediately before SIGN, in the same session, so
    /// the device clear-signs the `transfer(address,uint256)` ("Send 1
    /// USDC to 0x…") instead of rejecting with 0x6A80 unless blind
    /// signing is on. Best-effort: if the device rejects the
    /// descriptor (unknown token / old app), we fall through to SIGN
    /// and the existing 0x6A80 blind-sign guidance still applies.
    func signEthereumTransaction(
        envelope: Data,
        account: UInt32,
        erc20Descriptor: Data? = nil
    ) async throws -> (v: UInt8, r: Data, s: Data) {
        defer { resetSession() }
        try await ensureConnected()
        let sdk = ethereumSDK()
        if let erc20Descriptor {
            do {
                try await sdk.provideErc20TokenInformation(tokenInfo: erc20Descriptor)
            } catch {
                LogStore.shared.info(
                    "ledger.eth",
                    "ERC-20 token info rejected (\(error)); falling back to blind-sign path"
                )
            }
        }
        do {
            let sig = try await sdk.signTransactionForAccount(
                account: account,
                envelope: envelope
            )
            return (sig.v, Data(sig.r), Data(sig.s))
        } catch {
            throw mapEthereumSDKError(error, command: "SIGN_TRANSACTION")
        }
    }

    func signMessage(_ message: Data) async throws -> Data {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let sig = try await ethereumSDK().signPersonalMessageForAccount(
                account: 0,
                message: message
            )
            // Wire format we ship to the server: R(32) || S(32). The
            // recovery byte is dropped, the server has the public key.
            var out = Data()
            out.append(Data(sig.r))
            out.append(Data(sig.s))
            return out
        } catch {
            throw mapEthereumSDKError(error, command: "SIGN_PERSONAL_MESSAGE")
        }
    }

    // MARK: -- Bitcoin app APDUs (M4, skeleton)
    //
    // Real Ledger Bitcoin app v2 protocol details, sourced from
    // LedgerHQ/app-bitcoin-new (bitcoin_client/ledger_bitcoin/btchip.py):
    //
    //   CLA 0xE1 ("new" Bitcoin app v2). Older Bitcoin app used CLA 0xE0.
    //   INS 0x00 = GET_EXTENDED_PUBKEY
    //   INS 0x02 = REGISTER_WALLET
    //   INS 0x03 = GET_WALLET_ADDRESS
    //   INS 0x04 = SIGN_PSBT
    //   INS 0x05 = GET_MASTER_FINGERPRINT
    //   INS 0x10 = SIGN_MESSAGE
    //
    // GET_EXTENDED_PUBKEY data:
    //   1B(display_flag) || 1B(pathLen) || path_components (4B BE each)
    //   response: ascii xpub string
    //
    // GET_MASTER_FINGERPRINT data: empty
    //   response: 4 bytes (the BIP32 master fingerprint)
    //
    // SIGN_PSBT is significantly more involved (interactive PSBT v2
    // walkthrough with multiple round-trips, per-output user
    // confirmation, optional REGISTER_WALLET for non-standard
    // descriptors). The skeleton below sends one round-trip so
    // BitcoinSendView can surface a clear "switch to the Bitcoin app"
    // message when the chain returns 0x6E00 ("Class not supported").
    // A full implementation is multi-day work and needs real hardware
    // to validate; tracked as a follow-up.

    // MARK: -- Bitcoin (via ledger-btc-core SDK)
    //
    // All Bitcoin protocol work now delegates to ledger-btc-core's
    // LedgerBitcoinClient, which wraps LedgerHQ's official
    // `ledger_bitcoin_client` Rust crate. Maknoon keeps its own
    // BLE state machine; the SDK consumes a small adapter that
    // routes APDU exchange back through `sendAPDU`.

    /// Lazily-constructed SDK client. Survives across multiple
    /// method calls so we don't pay UniFFI handle-allocation cost
    /// per APDU. Reset by `resetSession()` so a reconnect builds
    /// a fresh one.
    private var bitcoinClient: LedgerBitcoinClient?

    private func bitcoinSDK() -> LedgerBitcoinClient {
        if let c = bitcoinClient { return c }
        let adapter = BitcoinTransportAdapter(parent: self)
        let c = LedgerBitcoinClient(transport: adapter)
        bitcoinClient = c
        return c
    }

    func getBitcoinAccountXpub(account: UInt32, networkCoinType: UInt32) async throws -> String {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let path = "m/84'/\(networkCoinType)'/\(account)'"
            return try await bitcoinSDK().getExtendedPubkey(path: path, display: false)
        } catch {
            throw mapBitcoinSDKError(error, command: "GET_EXTENDED_PUBKEY", coinType: networkCoinType)
        }
    }

    /// Returns the 4-byte BIP32 master fingerprint as an 8-char
    /// lowercase hex string. Used by the wallet-add flow to build
    /// a valid BIP84 watch-only descriptor (BDK rejects descriptors
    /// with a placeholder fingerprint that doesn't actually match
    /// the master key the xpub was derived from).
    func getBitcoinMasterFingerprint(networkCoinType: UInt32 = 0) async throws -> String {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let fp = try await bitcoinSDK().getMasterFingerprint()
            return fp.map { String(format: "%02x", $0) }.joined()
        } catch {
            throw mapBitcoinSDKError(error, command: "GET_MASTER_FINGERPRINT", coinType: networkCoinType)
        }
    }

    func signPSBT(_ psbt: Data, networkCoinType: UInt32) async throws -> Data {
        throw HardwareWalletError.transport("signPSBT(psbt:networkCoinType:) needs descriptor context; call signBitcoinPSBT(unsigned:fingerprint:xpub:account:coinType:) instead")
    }

    // MARK: -- Solana (via ledger-sol-core SDK)
    //
    // Solana protocol work delegates to ledger-sol-core's
    // LedgerSolanaClient, which hand-rolls the Solana app APDUs
    // (CLA=0xE0 INS=0x05 GET_PUBKEY, INS=0x06 SIGN_MESSAGE) using
    // the same UniFFI Transport pattern as Bitcoin. BIP44 path
    // is m/44'/501'/<account>'/0' per the Solana standard.

    private var solanaClient: LedgerSolanaClient?

    private func solanaSDK() -> LedgerSolanaClient {
        if let c = solanaClient { return c }
        let adapter = SolanaTransportAdapter(parent: self)
        let c = LedgerSolanaClient(transport: adapter)
        solanaClient = c
        return c
    }

    func getSolanaAddress(account: UInt32) async throws -> String {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let addr = try await solanaSDK().getAddressForAccount(account: account, display: false)
            return addr.base58
        } catch {
            throw mapSolanaSDKError(error, command: "GET_PUBKEY")
        }
    }

    func signSolanaTransaction(unsignedTx: Data, account: UInt32) async throws -> Data {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let sig = try await solanaSDK().signTransactionForAccount(
                account: account,
                message: unsignedTx
            )
            return Data(sig.bytes)
        } catch {
            throw mapSolanaSDKError(error, command: "SIGN_MESSAGE")
        }
    }

    // MARK: -- Ethereum (via ledger-eth-core SDK)
    //
    // The hand-rolled Swift APDU code that used to live in this
    // file is now in Rust. iOS just owns BLE; the SDK does APDU
    // encoding, EIP-55 derivation, and chunked SIGN.

    private var ethereumClient: LedgerEthClient?

    private func ethereumSDK() -> LedgerEthClient {
        if let c = ethereumClient { return c }
        let adapter = EthereumTransportAdapter(parent: self)
        let c = LedgerEthClient(transport: adapter)
        ethereumClient = c
        return c
    }

    private func mapEthereumSDKError(_ error: Error, command: String) -> HardwareWalletError {
        if let le = error as? LedgerEthError {
            switch le {
            case .DeviceRejected(let statusWord, _):
                return HardwareWalletError.transport(diagnose(swForEthereumAPDU: statusWord, command: command))
            case .UserCanceled:
                return HardwareWalletError.userCancelled
            case .Transport(let reason),
                 .InvalidPath(let reason),
                 .InvalidEnvelope(let reason),
                 .Protocol(let reason):
                return HardwareWalletError.transport("\(command) failed: \(reason)")
            }
        }
        if let hwe = error as? HardwareWalletError { return hwe }
        return HardwareWalletError.transport("\(command) failed: \(error.localizedDescription)")
    }

    // MARK: -- Tron (via ledger-tron-core SDK)

    private var tronClient: LedgerTronClient?

    private func tronSDK() -> LedgerTronClient {
        if let c = tronClient { return c }
        let adapter = TronTransportAdapter(parent: self)
        let c = LedgerTronClient(transport: adapter)
        tronClient = c
        return c
    }

    func getTronAddress(account: UInt32) async throws -> String {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let addr = try await tronSDK().getAddressForAccount(account: account, display: false)
            return addr.base58check
        } catch {
            throw mapTronSDKError(error, command: "GET_PUBLIC_KEY")
        }
    }

    func getTronPubkey(account: UInt32) async throws -> Data {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let addr = try await tronSDK().getAddressForAccount(account: account, display: false)
            return Data(addr.pubkey)
        } catch {
            throw mapTronSDKError(error, command: "GET_PUBLIC_KEY")
        }
    }

    func signTronTransaction(
        rawTxProto: Data,
        account: UInt32
    ) async throws -> (v: UInt8, r: Data, s: Data) {
        defer { resetSession() }
        try await ensureConnected()
        do {
            let sig = try await tronSDK().signTransactionForAccount(
                account: account,
                rawData: rawTxProto
            )
            return (sig.v, Data(sig.r), Data(sig.s))
        } catch {
            throw mapTronSDKError(error, command: "SIGN")
        }
    }

    private func mapTronSDKError(_ error: Error, command: String) -> HardwareWalletError {
        if let le = error as? LedgerTronError {
            switch le {
            case .DeviceRejected(let statusWord, _):
                return HardwareWalletError.transport(diagnoseTronSW(statusWord, command: command))
            case .UserCanceled:
                return HardwareWalletError.userCancelled
            case .Transport(let reason),
                 .InvalidPath(let reason),
                 .InvalidTransaction(let reason),
                 .Protocol(let reason):
                return HardwareWalletError.transport("\(command) failed: \(reason)")
            }
        }
        if let hwe = error as? HardwareWalletError { return hwe }
        return HardwareWalletError.transport("\(command) failed: \(error.localizedDescription)")
    }

    /// Translate ledger-sol-core's typed errors into HardwareWalletError
    /// with diagnostic copy specific to the Solana app being open vs
    /// the dashboard / wrong app. Same shape as mapBitcoinSDKError.
    private func mapSolanaSDKError(_ error: Error, command: String) -> HardwareWalletError {
        if let le = error as? LedgerSolError {
            switch le {
            case .DeviceRejected(let statusWord, _):
                return HardwareWalletError.transport(diagnoseSolanaSW(statusWord, command: command))
            case .UserCanceled:
                return HardwareWalletError.transport("\(command) failed: you declined the on-device confirmation. Approve on the Ledger and retry.")
            case .Transport(let reason),
                 .InvalidPath(let reason),
                 .InvalidMessage(let reason),
                 .Protocol(let reason):
                return HardwareWalletError.transport("\(command) failed: \(reason)")
            }
        }
        if let hwe = error as? HardwareWalletError {
            return hwe
        }
        return HardwareWalletError.transport("\(command) failed: \(error.localizedDescription)")
    }

    /// Signs a PSBT v0 against a default BIP-84 single-sig policy.
    /// Returns the signed PSBT v0 base64 with PSBT_IN_PARTIAL_SIG
    /// entries merged in; BDK can finalise + broadcast directly.
    func signBitcoinPSBT(
        unsignedBase64: String,
        fingerprintHex: String,
        accountXpub: String,
        account: UInt32,
        coinType: UInt32
    ) async throws -> String {
        defer { resetSession() }
        try await ensureConnected()
        let keyOrigin = "[\(fingerprintHex)/84'/\(coinType)'/\(account)']\(accountXpub)"
        let policy = WalletPolicy(
            name: "",
            descriptorTemplate: "wpkh(@0/**)",
            keys: [keyOrigin],
            hmac: nil
        )
        do {
            return try await bitcoinSDK().signPsbt(psbtBase64: unsignedBase64, policy: policy)
        } catch {
            throw mapBitcoinSDKError(error, command: "SIGN_PSBT", coinType: coinType)
        }
    }

    /// Get the master fingerprint on a known network. `coinType` only
    /// affects the diagnostic copy when an error surfaces (so the user
    /// is told to open "Bitcoin Test" instead of "Bitcoin" on testnet
    /// flows); the underlying GET_MASTER_FINGERPRINT APDU is the same.
    private func mapBitcoinSDKError(_ error: Error, command: String, coinType: UInt32 = 0) -> HardwareWalletError {
        if let le = error as? LedgerError {
            switch le {
            case .DeviceRejected(let statusWord, _):
                return HardwareWalletError.transport(diagnoseBitcoinSW(statusWord, command: command, coinType: coinType))
            case .UserCanceled:
                return HardwareWalletError.transport("\(command) failed: you declined the on-device confirmation. Approve on the Ledger and retry.")
            case .Transport(let reason),
                 .InvalidPsbt(let reason),
                 .InvalidPolicy(let reason),
                 .Protocol(let reason):
                return HardwareWalletError.transport("\(command) failed: \(reason)")
            }
        }
        if error is HardwareWalletError {
            // Bubbled up from inside the adapter without going through
            // the SDK error mapping (e.g. BLE disconnect mid-exchange).
            return error as! HardwareWalletError
        }
        return HardwareWalletError.transport("\(command) failed: \(error.localizedDescription)")
    }
}

// MARK: -- SDK Transport adapter
//
// Bridges the SDK's UniFFI-generated Transport callback into
// Maknoon's BLE state machine. The SDK invokes `exchange(apdu:)`
// for each APDU it needs to send; we route the call through
// LedgerBLE.sendAPDU, which already handles 5-byte BLE framing,
// 153-byte MTU chunking, multi-packet reassembly, and the
// Battery Service keep-alive heartbeat.
private final class BitcoinTransportAdapter: Transport, @unchecked Sendable {
    private weak var parent: LedgerBLE?

    init(parent: LedgerBLE) {
        self.parent = parent
    }

    func exchange(apdu: Data) async throws -> ExchangeResponse {
        guard let parent else {
            throw TransportError.Disconnected(reason: "LedgerBLE deallocated mid-exchange")
        }
        do {
            let (data, sw) = try await parent.bitcoinTransportSend(apdu: apdu)
            return ExchangeResponse(statusWord: sw, data: data)
        } catch let hwError as HardwareWalletError {
            // Preserve the actual description rather than the NSError-
            // bridged default which collapses every HardwareWalletError
            // case to "The operation couldn't be completed."
            throw TransportError.Io(reason: hwError.description)
        } catch {
            throw TransportError.Io(reason: error.localizedDescription)
        }
    }
}

extension LedgerBLE {
    // Fileprivate trampoline so the adapter (a top-level type in
    // this file) can reach `sendAPDU`, which is private to the
    // class. Keeps `sendAPDU`'s visibility constrained and avoids
    // changing access on the existing call path.
    fileprivate func bitcoinTransportSend(apdu: Data) async throws -> (data: Data, sw: UInt16) {
        try await sendAPDU(apdu)
    }

    fileprivate func solanaTransportSend(apdu: Data) async throws -> (data: Data, sw: UInt16) {
        try await sendAPDU(apdu)
    }

    fileprivate func ethereumTransportSend(apdu: Data) async throws -> (data: Data, sw: UInt16) {
        try await sendAPDU(apdu)
    }

    fileprivate func tronTransportSend(apdu: Data) async throws -> (data: Data, sw: UInt16) {
        try await sendAPDU(apdu)
    }
}

// Solana SDK transport adapter. Same plumbing as
// BitcoinTransportAdapter: the SDK invokes `exchange(apdu:)`
// per APDU, we route through LedgerBLE.sendAPDU.
private final class SolanaTransportAdapter: SolanaLedgerTransport, @unchecked Sendable {
    private weak var parent: LedgerBLE?

    init(parent: LedgerBLE) {
        self.parent = parent
    }

    func exchange(apdu: Data) async throws -> SolanaExchangeResponse {
        guard let parent else {
            throw SolanaTransportError.Disconnected(reason: "LedgerBLE deallocated mid-exchange")
        }
        do {
            let (data, sw) = try await parent.solanaTransportSend(apdu: apdu)
            return SolanaExchangeResponse(statusWord: sw, data: data)
        } catch let hwError as HardwareWalletError {
            throw SolanaTransportError.Io(reason: hwError.description)
        } catch {
            throw SolanaTransportError.Io(reason: error.localizedDescription)
        }
    }
}

// Ethereum SDK transport adapter.
private final class EthereumTransportAdapter: EthLedgerTransport, @unchecked Sendable {
    private weak var parent: LedgerBLE?

    init(parent: LedgerBLE) { self.parent = parent }

    func exchange(apdu: Data) async throws -> EthExchangeResponse {
        guard let parent else {
            throw EthTransportError.Disconnected(reason: "LedgerBLE deallocated mid-exchange")
        }
        do {
            let (data, sw) = try await parent.ethereumTransportSend(apdu: apdu)
            return EthExchangeResponse(statusWord: sw, data: data)
        } catch let hwError as HardwareWalletError {
            throw EthTransportError.Io(reason: hwError.description)
        } catch {
            throw EthTransportError.Io(reason: error.localizedDescription)
        }
    }
}

// Tron SDK transport adapter.
private final class TronTransportAdapter: TronLedgerTransport, @unchecked Sendable {
    private weak var parent: LedgerBLE?

    init(parent: LedgerBLE) { self.parent = parent }

    func exchange(apdu: Data) async throws -> TronExchangeResponse {
        guard let parent else {
            throw TronTransportError.Disconnected(reason: "LedgerBLE deallocated mid-exchange")
        }
        do {
            let (data, sw) = try await parent.tronTransportSend(apdu: apdu)
            return TronExchangeResponse(statusWord: sw, data: data)
        } catch let hwError as HardwareWalletError {
            // Preserve the actual description rather than the NSError-
            // bridged "The operation couldn't be completed." default.
            throw TronTransportError.Io(reason: hwError.description)
        } catch {
            throw TronTransportError.Io(reason: error.localizedDescription)
        }
    }
}

/// SW interpretation for the Ledger Tron app. Mirrors
/// `diagnoseSolanaSW`: tell the user the right app to open
/// rather than dumping the raw status word.
private func diagnoseTronSW(_ sw: UInt16, command: String) -> String {
    switch sw {
    case 0x6511, 0x6D02:
        return "\(command) failed: Ledger is on the dashboard. Unlock the device and open the TRON app, then retry."
    case 0x6E00:
        return "\(command) failed: the Tron app didn't recognise the request. Install / open the current Tron app from Ledger Live and retry. Status 0x6E00."
    case 0x6D00:
        return "\(command) failed: the open Tron app does not support this instruction. Update via Ledger Live. Status 0x6D00."
    case 0x6985:
        return "\(command) failed: you declined the on-device confirmation. Approve on the Ledger and retry."
    case 0x6A8D:
        // The Tron app refuses to sign a TriggerSmartContract (TRC-20
        // transfer) to a contract it doesn't have a clearsign
        // template for, unless the user opts in. The toggle is in the
        // Tron app's on-device settings.
        return "\(command) failed: the Tron app blocked this TRC-20 transfer (status 0x6A8D). On the Ledger, open the Tron app → Settings and enable \"Custom contracts\" (allow signing transactions to contracts the app doesn't recognise). If your firmware labels it differently, enabling \"Transactions data\" or \"Sign by hash\" achieves the same. Then retry."
    case 0x6700, 0x6A80, 0x6A86, 0x6A87:
        return "\(command) failed: Ledger rejected the APDU as malformed (status 0x\(String(sw, radix: 16))). This is a Maknoon bug, paste this error so we can fix the encoding."
    default:
        return "\(command) failed: Ledger returned status 0x\(String(sw, radix: 16)). Open the Tron app and retry."
    }
}

/// SW interpretation for the Ledger Solana app. Mirrors
/// `diagnoseBitcoinSW`: tell the user the right app to open
/// rather than dumping the raw status word.
private func diagnoseSolanaSW(_ sw: UInt16, command: String) -> String {
    switch sw {
    case 0x6511, 0x6D02:
        return "\(command) failed: Ledger is on the dashboard. Unlock the device and open the SOLANA app, then retry."
    case 0x6E00:
        return "\(command) failed: the Solana app didn't recognise the request. Install / open the current Solana app from Ledger Live and retry. Status 0x6E00."
    case 0x6D00:
        return "\(command) failed: the open Solana app does not support this instruction. Update via Ledger Live. Status 0x6D00."
    case 0x6985:
        return "\(command) failed: you declined the on-device confirmation. Approve on the Ledger and retry."
    case 0x6700, 0x6A80, 0x6A86, 0x6A87:
        return "\(command) failed: Ledger rejected the APDU as malformed (status 0x\(String(sw, radix: 16))). This is a Maknoon bug, paste this error so we can fix the encoding."
    default:
        return "\(command) failed: Ledger returned status 0x\(String(sw, radix: 16)). Open the Solana app and retry."
    }
}

// MARK: -- status-word diagnostics
//
// Common Ledger status words and what they mean in practice:
//   0x6511 / 0x6D02   "Required app is not opened." Most common cause:
//                     Ledger is unlocked and showing the dashboard.
//   0x6E00            "INS not supported." Almost always means the
//                     wrong app is open (we sent an Ethereum APDU
//                     while the Bitcoin app was foregrounded, or
//                     vice versa). Switch apps and retry.
//   0x6985            User rejected the on-device confirmation.
//   0x9000            Success.
/// SW interpretation for app-bitcoin-new (Bitcoin app v2).
/// Distinguishes "wrong app open" from "wrong app version" since the
/// modern Bitcoin app (CLA=0xE1) returns 0x6E00 for the legacy app's
/// CLA=0xE0, AND the legacy app returns 0x6E00 when we send 0xE1.
/// Same SW, two diagnoses depending on what's installed.
private func diagnoseBitcoinSW(_ sw: UInt16, command: String, coinType: UInt32 = 0) -> String {
    // Ledger ships a separate app for testnet derivation paths. Tell
    // the user the right one to open rather than always saying
    // "Bitcoin" and watching them retry on the wrong app.
    let appName = coinType == 0 ? "Bitcoin" : "Bitcoin Test"
    switch sw {
    case 0x6511, 0x6D02:
        return "\(command) failed: Ledger is on the dashboard. Unlock the device and open the \(appName.uppercased()) app, then retry."
    case 0x6E00:
        return "\(command) failed: the \(appName) app didn't recognise the request. Most likely cause: you have the legacy app installed instead of the modern v2 app. Install the current '\(appName)' app from Ledger Live and open that one. Status 0x6E00 (CLA not supported)."
    case 0x6D00:
        return "\(command) failed: the open \(appName) app does not support this instruction. You may be on an outdated firmware/app version. Update via Ledger Live. Status 0x6D00 (INS not supported)."
    case 0x6985:
        return "\(command) failed: you declined the on-device confirmation. Approve on the Ledger and retry."
    case 0x6700, 0x6A80, 0x6A86, 0x6A87:
        return "\(command) failed: Ledger rejected the APDU as malformed (status 0x\(String(sw, radix: 16))). This is a Maknoon bug, paste this whole error so we can fix the encoding."
    default:
        return "\(command) failed: Ledger returned status 0x\(String(sw, radix: 16)). Open the \(appName) app and retry; if the same status repeats, paste it so we can diagnose."
    }
}

private func diagnose(swForEthereumAPDU sw: UInt16, command: String = "") -> String {
    switch sw {
    case 0x6511, 0x6D02:
        return "Ledger is showing the dashboard. Unlock the Ledger and OPEN THE ETHEREUM APP, then retry pairing. Pairing today uses the Ethereum app for the secp256k1 attestation; Bitcoin app support for hardware-wallet Bitcoin sending is a separate, not-yet-shipped flow."
    case 0x6E00:
        return "Ledger has a different app open. SWITCH TO THE ETHEREUM APP on the device (Bitcoin app uses different APDU codes that we don't yet pair against), then retry."
    case 0x6985:
        return "You declined the on-device confirmation. Tap the right button on the Ledger to approve, then retry."
    case 0x6A80:
        // The Ledger Ethereum app rejected SIGN_TRANSACTION because
        // the calldata (e.g. an ERC-20 `transfer`) has no clearsign
        // template the device can render, and Blind Signing is
        // disabled. Native ETH sends never carry calldata so they
        // don't hit this branch. The proper fix is to send
        // PROVIDE_ERC20_TOKEN_INFORMATION with Ledger's signed token
        // blob before SIGN; until that lands, the user can flip
        // Blind Signing on instead.
        if command.hasPrefix("SIGN_TRANSACTION") {
            return "Ledger rejected the transaction (status 0x6A80). For ERC-20 transfers (USDC, USDT, …), enable Blind Signing on the device: Ethereum app → ⚙ Settings → Blind signing → Enabled, then retry. Native ETH sends don't need this."
        }
        return "Ledger returned status 0x6A80 (incorrect data). Confirm the Ethereum app is open + up to date, then retry."
    default:
        return "Ledger returned status 0x\(String(sw, radix: 16)). Wake the device, unlock it, open the Ethereum app, then retry."
    }
}

// MARK: -- APDU + framing helpers

private func buildAPDU(cla: UInt8, ins: UInt8, p1: UInt8, p2: UInt8, data: Data) -> Data {
    // ISO 7816-4 case 1 (no data): the APDU is just the 4-byte
    // header. If we instead emit `header || 0x00` the Ledger Bitcoin
    // app reads the extra byte as a malformed Lc and returns
    // 0x6A87 ("wrong Lc or Le"). GET_MASTER_FINGERPRINT is the
    // motivating call site.
    if data.isEmpty {
        return Data([cla, ins, p1, p2])
    }
    var apdu = Data([cla, ins, p1, p2, UInt8(data.count)])
    apdu.append(data)
    return apdu
}

private func framedPackets(apdu: Data, mtu: Int) -> [Data] {
    var packets: [Data] = []
    var index: UInt16 = 0
    var offset = 0
    while offset < apdu.count {
        var packet = Data()
        packet.append(bleApduTag)
        packet.append(contentsOf: withUnsafeBytes(of: index.bigEndian, Array.init))
        var take = mtu - 3
        if index == 0 {
            packet.append(contentsOf: withUnsafeBytes(of: UInt16(apdu.count).bigEndian, Array.init))
            take -= 2
        }
        let end = min(offset + take, apdu.count)
        packet.append(apdu.subdata(in: offset..<end))
        packets.append(packet)
        offset = end
        index &+= 1
    }
    return packets
}

/// Compresses an uncompressed secp256k1 pubkey (0x04 || X || Y) into the
/// 33-byte compressed form (0x02 or 0x03 || X). The server doesn't care
/// which form is used as long as the @noble/secp256k1 verify accepts it;
/// we standardise on compressed for shorter Presentation payloads.
private func compressSecp256k1Pubkey(_ raw: Data) -> Data {
    guard raw.count == 65, raw[0] == 0x04 else { return raw }
    let x = raw.subdata(in: 1..<33)
    let yIsEven = (raw[64] & 0x01) == 0
    var out = Data([yIsEven ? 0x02 : 0x03])
    out.append(x)
    return out
}

// MARK: -- CB delegates

extension LedgerBLE: CBCentralManagerDelegate {
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
        // Multi-device safety: if a target UUID was configured for
        // this session, ignore advertisements from any other Ledger
        // the user happens to have paired. Without a target (the
        // unknown-pairing case), accept the first match as before.
        if let target = targetPeripheralUUID, peripheral.identifier != target {
            return
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        LogStore.shared.info("ledger.ble", "connected \(peripheral.identifier.uuidString)")
        connectedContinuation?.resume()
        connectedContinuation = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let codeStr: String
        if let cberror = error as? CBError {
            codeStr = " [CBError code=\(cberror.errorCode)]"
        } else {
            codeStr = ""
        }
        let reason = (error?.localizedDescription ?? "unknown") + codeStr
        LogStore.shared.error("ledger.ble", "connect failed for \(peripheral.identifier.uuidString): \(reason)")
        connectedContinuation?.resume(throwing: HardwareWalletError.transport("connect failed: \(reason). Try iOS Settings → Bluetooth → Forget the Nano X, then re-pair."))
        connectedContinuation = nil
    }

    /// The Ledger dropped (user locked it, switched apps, walked out
    /// of range, etc.). Fail every pending continuation explicitly so
    /// the UI surfaces an error instead of hanging — and so a late
    /// notify on a now-stale peripheral cannot double-resume an
    /// already-completed continuation, which would crash the app.
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // Capture the raw CBError code so we can distinguish "OS
        // timed out the connect attempt" from "device walked out of
        // range" from "another app is using this device." The
        // localized string is identical for several of these
        // failure modes ("The connection has timed out
        // unexpectedly") but the codes are different.
        let codeStr: String
        if let cberror = error as? CBError {
            codeStr = " [CBError code=\(cberror.errorCode)]"
        } else if let err = error {
            codeStr = " [\(type(of: err))]"
        } else {
            codeStr = ""
        }
        let reason = (error?.localizedDescription ?? "device disconnected") + codeStr
        LogStore.shared.warn("ledger.ble", "disconnected \(peripheral.identifier.uuidString): \(reason)")
        pendingAPDU?.continuation?.resume(throwing: HardwareWalletError.transport("Ledger disconnected: \(reason). Try iOS Settings → Bluetooth → Forget the Nano X, then re-pair. Or toggle Bluetooth off and on."))
        pendingAPDU = nil
        connectedContinuation?.resume(throwing: HardwareWalletError.transport("Ledger disconnected: \(reason). Try iOS Settings → Bluetooth → Forget the Nano X, then re-pair. Or toggle Bluetooth off and on."))
        connectedContinuation = nil
        servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("Ledger disconnected: \(reason). Try iOS Settings → Bluetooth → Forget the Nano X, then re-pair. Or toggle Bluetooth off and on."))
        servicesReadyContinuation = nil
        writeChar = nil
        notifyChar = nil
        batteryLevelChar = nil
        self.peripheral = nil
    }
}

extension LedgerBLE: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("service discovery failed"))
            servicesReadyContinuation = nil
            return
        }
        for svc in services {
            if svc.uuid == ledgerServiceUUID {
                peripheral.discoverCharacteristics([ledgerWriteUUID, ledgerNotifyUUID], for: svc)
            } else if svc.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelUUID], for: svc)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let chars = service.characteristics ?? []
        if service.uuid == batteryServiceUUID {
            // Battery service is best-effort for keep-alive. If we
            // can't resolve the Battery Level characteristic for any
            // reason, just continue without it: the heartbeat
            // becomes a no-op and the only consequence is shorter
            // on-device confirmation windows.
            batteryLevelChar = chars.first { $0.uuid == batteryLevelUUID }
            return
        }
        // Ledger APDU service: required, gate readiness on it.
        guard !chars.isEmpty else {
            servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("characteristic discovery failed"))
            servicesReadyContinuation = nil
            return
        }
        writeChar = chars.first { $0.uuid == ledgerWriteUUID }
        notifyChar = chars.first { $0.uuid == ledgerNotifyUUID }
        guard let notifyChar else {
            servicesReadyContinuation?.resume(throwing: HardwareWalletError.transport("notify characteristic missing"))
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
        // Battery Level reads are keep-alive traffic only. Silently
        // consume them so they don't reach the APDU state machine.
        if characteristic.uuid == batteryLevelUUID { return }
        guard characteristic.uuid == ledgerNotifyUUID, let data = characteristic.value else { return }
        // Snapshot + clear pendingAPDU FIRST so a re-entrant notify
        // delivered while we're still building the buffer cannot see
        // a half-completed state and double-resume.
        guard var pending = pendingAPDU else { return }
        pendingAPDU = nil
        // Strip the 3- or 5-byte BLE framing header per packet.
        guard data.count >= 3, data[0] == bleApduTag else {
            // Malformed packet — put the pending state back so the
            // next legitimate notify can continue. We don't fail the
            // continuation outright; the timeout race in sendAPDU is
            // the backstop.
            pendingAPDU = pending
            return
        }
        let packetIdx = (UInt16(data[1]) << 8) | UInt16(data[2])
        var payloadStart = 3
        if packetIdx == 0 {
            guard data.count >= 5 else {
                pendingAPDU = pending
                return
            }
            pending.totalLength = Int(UInt16(data[3]) << 8 | UInt16(data[4]))
            payloadStart = 5
        }
        pending.buffer.append(data.subdata(in: payloadStart..<data.count))
        if pending.buffer.count >= pending.totalLength && pending.totalLength >= 0 {
            let cont = pending.continuation
            pending.continuation = nil    // belt + suspenders: clear before resuming
            let full = pending.buffer.prefix(pending.totalLength)
            cont?.resume(returning: Data(full))
        } else {
            pendingAPDU = pending
        }
    }
}
