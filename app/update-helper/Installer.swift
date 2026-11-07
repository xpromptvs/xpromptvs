import Foundation
import ShellstormCore
public enum Installer {
    /// Homebrew owns replacement and its receipts. Never restore a bundle behind its back.
    public static func upgrade(journalURL:URL,upgrade:()throws->Void,verify:(URL)throws->Void,verifyRemaining:(URL)throws->Void,launchAndConfirm:(URL)throws->Void) throws {
        var j=try HostUpdateJournal.read(journalURL)
        let installed=URL(fileURLWithPath:j.installed)
        do {
            j.phase="installing";try j.write(to:journalURL)
            try upgrade()
            try verify(installed)
            j.phase="launching";try j.write(to:journalURL)
            try launchAndConfirm(installed)
            j.phase="succeeded"
        } catch {
            j.error="Homebrew update or startup failed. Check this Mac locally."
            j.phase="recovering";try j.write(to:journalURL)
            // Homebrew may have restored the old version after an installation failure.
            // Reopen what remains; never claim that it was rolled back by this helper.
            if FileManager.default.fileExists(atPath:installed.path) {
                do {try verifyRemaining(installed);try launchAndConfirm(installed)} catch {}
            }
            j.phase="failed"
        }
        j.pairingCarrier=nil
        try j.write(to:journalURL)
    }
}
