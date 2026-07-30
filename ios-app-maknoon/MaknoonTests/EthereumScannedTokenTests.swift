import XCTest
@testable import Maknoon

/// Locks the classification a scanned token QR gets against one wallet's token
/// list. The motivating case is bridged USDC.e (0xff97…5cc8) requested while the
/// wallet holds native USDC (0xaf88…5831): both report symbol() == "USDC" on
/// chain, so this must surface the held token as a CANDIDATE the user picks,
/// never as an automatic substitution.
final class EthereumScannedTokenTests: XCTestCase {

    private static let nativeUSDC = EthereumToken(
        network: .arbitrum,
        contractAddress: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        symbol: "USDC", name: "USD Coin", decimals: 6, curated: false
    )
    private static let bridgedUSDC = EthereumToken(
        network: .arbitrum,
        contractAddress: "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8",
        symbol: "USDC", name: "USD Coin (Arb1)", decimals: 6, curated: false
    )
    private static let arb = EthereumToken(
        network: .arbitrum,
        contractAddress: "0x912ce59144191c1204e64559fe8253a0e49e6548",
        symbol: "ARB", name: "Arbitrum", decimals: 18, curated: false
    )

    /// The exact contract wins even though a same-symbol token is also present.
    func testExactContractBeatsSameSymbol() {
        let match = EthereumScannedToken.resolve(
            requestedContract: "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8",
            requestedSymbol: "USDC",
            added: [Self.nativeUSDC, Self.bridgedUSDC]
        )
        XCTAssertEqual(match, .alreadyAdded(Self.bridgedUSDC))
    }

    /// The QR's target is checksummed, the store's is lowercase.
    func testContractCompareIsCaseInsensitive() {
        let match = EthereumScannedToken.resolve(
            requestedContract: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
            requestedSymbol: "USDC",
            added: [Self.bridgedUSDC]
        )
        XCTAssertEqual(match, .alreadyAdded(Self.bridgedUSDC))
    }

    /// The real-world case: bridged requested, only native held.
    func testAbsentContractSurfacesSameSymbolHolding() {
        let match = EthereumScannedToken.resolve(
            requestedContract: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8",
            requestedSymbol: "USDC",
            added: [Self.nativeUSDC, Self.arb]
        )
        XCTAssertEqual(match, .sameSymbolCandidates([Self.nativeUSDC]))
    }

    /// Every same-symbol holding is offered, and the requested contract itself is
    /// never listed as its own alternative.
    func testAllSameSymbolCandidatesReturnedExcludingTheRequestedOne() {
        let otherUSDC = EthereumToken(
            network: .arbitrum,
            contractAddress: "0x1111111111111111111111111111111111111111",
            symbol: "usdc", name: "Some other USDC", decimals: 6, curated: false
        )
        let match = EthereumScannedToken.resolve(
            requestedContract: "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8",
            requestedSymbol: "USDC",
            added: [Self.nativeUSDC, otherUSDC, Self.arb]
        )
        XCTAssertEqual(match, .sameSymbolCandidates([Self.nativeUSDC, otherUSDC]))
    }

    /// No holdings at all, or nothing with a matching symbol: only the add path.
    func testUnknownWhenNothingMatches() {
        XCTAssertEqual(
            EthereumScannedToken.resolve(
                requestedContract: "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8",
                requestedSymbol: "USDC",
                added: []
            ),
            .unknown
        )
        XCTAssertEqual(
            EthereumScannedToken.resolve(
                requestedContract: "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8",
                requestedSymbol: "USDC",
                added: [Self.arb]
            ),
            .unknown
        )
    }

    /// A failed probe leaves no symbol to match on, so a same-symbol holding must
    /// NOT be guessed at.
    func testNoProbedSymbolCannotProduceCandidates() {
        XCTAssertEqual(
            EthereumScannedToken.resolve(
                requestedContract: "0xff970a61a04b1ca14834a43f5de4533ebddb5cc8",
                requestedSymbol: nil,
                added: [Self.nativeUSDC]
            ),
            .unknown
        )
    }

    func testEmptyContractIsUnknown() {
        XCTAssertEqual(
            EthereumScannedToken.resolve(requestedContract: "  ", requestedSymbol: "USDC", added: [Self.nativeUSDC]),
            .unknown
        )
    }
}
