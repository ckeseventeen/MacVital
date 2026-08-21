import XCTest
@testable import MacVitalKit

/// `/Library/Preferences/org.cups.printers.plist` holds every printer the user
/// has configured, and the residue scanner was offering it for removal under a
/// privileged rule.
///
/// Every existing guard missed it, and each for a defensible reason: CUPS is
/// not an app, so attribution found nothing; the name carries no `com.apple.`
/// prefix, so the name filter passed it; and `pkgutil --file-info` reports no
/// package, because `cupsd` writes the file at runtime rather than an installer
/// placing it. The gap was that macOS ships whole subsystems under their
/// upstream reverse-DNS names.
final class SystemDomainTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SystemDomainIndex.invalidate()
    }

    func testCUPSIsRecognisedAsSystemOwned() {
        XCTAssertTrue(SystemDomainIndex.isSystemDomain("org.cups.printers"))
        XCTAssertTrue(SystemDomainIndex.isSystemDomain("org.cups.cups-lpd"))
    }

    /// The namespaces macOS ships that carry no Apple prefix.
    func testBundledOpenSourceSubsystemsAreSystemOwned() {
        for identifier in ["org.apache.httpd", "com.vix.cron", "org.openldap.slapd", "org.net-snmp.snmpd"] {
            XCTAssertTrue(SystemDomainIndex.isSystemDomain(identifier), identifier)
        }
    }

    /// The whole point is that it stays narrow. A vendor whose namespace the OS
    /// does not occupy must still be attributable as residue.
    func testThirdPartyIdentifiersAreNotClaimed() {
        for identifier in ["com.docker.vmnetd", "com.omiga.bitboo.ProxyConfigHelper",
                           "io.github.clash-verge-rev.clash-verge-rev.service",
                           "com.drbuho.BuhoCleaner.PrivilegedHelperTool"] {
            XCTAssertFalse(SystemDomainIndex.isSystemDomain(identifier), identifier)
        }
    }

    /// Matched on the vendor, not on a string prefix: `org.cupsomething` is a
    /// different vendor than `org.cups`.
    func testMatchIsOnWholeComponents() {
        XCTAssertFalse(SystemDomainIndex.isSystemDomain("org.cupsy.printers"))
        XCTAssertFalse(SystemDomainIndex.isSystemDomain("cups"))
    }

    /// A namespace does not stop being the OS's because the daemon that uses it
    /// is absent — a Mac with no printers configured must still refuse
    /// `org.cups.*`.
    func testKnownNamespacesDoNotDependOnWhatIsInstalled() {
        XCTAssertTrue(SystemDomainIndex.isSystemDomain("com.apple.anything"))
        XCTAssertTrue(SystemDomainIndex.isSystemDomain("org.cups.whatever"))
    }
}

/// `/Library` is shared by the OS and by every installer on the machine, so
/// "matches no installed app" is not evidence of residue there.
///
/// An audit of this machine found `/Library/Preferences/OpenDirectory` and
/// `/Library/Application Support/VMware` reaching the user, saved only by an
/// unrelated permissions check, and `org.cups.printers.plist` reaching them
/// outright.
final class SystemLibraryAttributionTests: XCTestCase {

    /// Every privileged residue rule points into `/Library`, and removing
    /// something there needs root — the most expensive place to be wrong. All
    /// of them must require an identifier-shaped name.
    func testEveryPrivilegedResidueRuleRequiresAnIdentifierName() {
        let privileged = RuleCatalog.all.filter { $0.requiresPrivilege && $0.category == .appResidue }
        XCTAssertFalse(privileged.isEmpty, "the catalog should still have privileged residue rules")

        for rule in privileged {
            XCTAssertTrue(
                AppResidueScanner.identifierKeyedRules.contains(rule.id),
                "\(rule.id) removes from /Library with root and must not accept a plain name"
            )
        }
    }

    /// The names that were being proposed, and the ones that must still be.
    func testPlainSystemNamesAreNotIdentifierShaped() {
        for name in ["OpenDirectory", "SystemConfiguration", "DirectoryService", "Audio", "Logging", "Xsan", "VMware"] {
            XCTAssertFalse(InstalledAppIndex.looksLikeBundleIdentifier(name), name)
        }
        for name in ["com.docker.vmnetd", "com.omiga.bitboo.ProxyConfigHelper"] {
            XCTAssertTrue(InstalledAppIndex.looksLikeBundleIdentifier(name), name)
        }
    }
}
