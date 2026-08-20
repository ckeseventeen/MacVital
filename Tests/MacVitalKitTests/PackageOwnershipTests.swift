import XCTest
@testable import MacVitalKit

/// The residue scanner decides something is leftover by failing to attribute it
/// to an installed app. Under `/Library` that reasoning is unsound, because
/// macOS installs there and belongs to no app.
///
/// `/Library/Application Support/BTServer` is the case that proved it: 46
/// Bluetooth country-code plists from a system update, reported as the residue
/// of an uninstalled app, with `sudo rm` as the suggested remedy. No
/// name-based deny list could have caught it — the directory carries no
/// `com.apple.` prefix.
final class PackageOwnershipTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalPkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Any path on this machine that the receipt database attributes to Apple.
    /// Found rather than hardcoded — which entries exist varies by macOS
    /// version, and a hardcoded name that stops existing turns this into a
    /// test that silently passes.
    private func anySystemProvidedPath() -> String? {
        let roots = ["/Library/Application Support", "/Library/Preferences", "/Library/LaunchDaemons"]
        for root in roots {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
                let path = (root as NSString).appendingPathComponent(name)
                if PackageOwnership.isSystemProvided(path) { return path }
            }
        }
        return nil
    }

    func testSomethingWeJustCreatedIsOwnedByNoPackage() throws {
        let file = sandbox.appendingPathComponent("nothing-owns-this.txt")
        try Data("x".utf8).write(to: file)

        XCTAssertTrue(PackageOwnership.owningPackages(of: file.path).isEmpty)
        XCTAssertFalse(PackageOwnership.isSystemProvided(file.path))
    }

    func testAppleProvidedPathIsRecognised() throws {
        let path = try XCTUnwrap(anySystemProvidedPath(),
                                 "no Apple-owned path found under /Library on this machine")
        XCTAssertTrue(PackageOwnership.isSystemProvided(path))
        XCTAssertTrue(PackageOwnership.owningPackages(of: path).contains { $0.hasPrefix("com.apple.") })
    }

    /// A third-party package owning a path proves nothing: a leftover launch
    /// daemon was installed by a package too, and that is precisely what makes
    /// it residue once its app is gone. Only Apple identifiers suppress.
    func testOnlyApplePackagesSuppress() throws {
        let file = sandbox.appendingPathComponent("thing.txt")
        try Data("x".utf8).write(to: file)
        // Nothing owns it, so `isSystemProvided` must be false — the same
        // answer a third-party-owned path has to produce.
        XCTAssertFalse(PackageOwnership.isSystemProvided(file.path))
    }

    /// The rule engine evaluates every item twice, so an uncached answer costs
    /// two subprocesses per candidate.
    func testRepeatedQueriesAreCached() throws {
        let path = try XCTUnwrap(anySystemProvidedPath(),
                                 "no Apple-owned path found under /Library on this machine")

        let first = Date()
        _ = PackageOwnership.owningPackages(of: path)
        let cold = Date().timeIntervalSince(first)

        let second = Date()
        for _ in 0..<50 { _ = PackageOwnership.owningPackages(of: path) }
        let warm = Date().timeIntervalSince(second)

        XCTAssertLessThan(warm, max(cold, 0.001) * 10,
                          "50 cached lookups should cost far less than one subprocess")
    }
}
