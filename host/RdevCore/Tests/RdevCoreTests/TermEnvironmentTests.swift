import XCTest
@testable import RdevCore

final class TermEnvironmentTests: XCTestCase {
    /// launchd's environment as the packaged app sees it (Mac mini, 2026-09-25).
    let launchd = [
        "HOME": "/Users/t", "USER": "t", "SHELL": "/bin/zsh",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
    ]

    func testLaunchdEnvironmentGainsTermColorAndLocale() {
        let env = TermEnvironment.environment(inherited: launchd)
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["HOME"], "/Users/t")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testParentTerminalDescriptionIsOverriddenAndStripped() {
        var parent = launchd
        parent["TERM"] = "tmux-256color"
        parent["COLORTERM"] = "24bit"
        parent["TERM_PROGRAM"] = "iTerm.app"
        parent["TMUX"] = "/tmp/tmux-501/default,1,0"
        let env = TermEnvironment.environment(inherited: parent)
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertNil(env["TERM_PROGRAM"])
        XCTAssertNil(env["TMUX"])
    }

    func testLauncherColorSuppressionDoesNotLeakIntoInteractiveTabs() {
        var parent = launchd
        parent["NO_COLOR"] = "1"
        let env = TermEnvironment.environment(inherited: parent)
        XCTAssertNil(env["NO_COLOR"], "The launcher is not the terminal tab's color policy")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
    }

    func testAnExistingLocaleIsKept() {
        for key in ["LANG", "LC_ALL", "LC_CTYPE"] {
            var parent = launchd
            parent[key] = "de_DE.UTF-8"
            let env = TermEnvironment.environment(inherited: parent)
            XCTAssertEqual(env[key], "de_DE.UTF-8", key)
            if key != "LANG" { XCTAssertNil(env["LANG"], key) }
        }
    }

    func testAnEmptyLocaleIsNoLocale() {
        var parent = launchd
        parent["LANG"] = ""
        XCTAssertEqual(TermEnvironment.environment(inherited: parent)["LANG"], "en_US.UTF-8")
    }

    func testEnvpIsSortedKeyValue() {
        XCTAssertEqual(TermEnvironment.envp(["B": "2", "A": "1=x"]), ["A=1=x", "B=2"])
    }

    func testLoginArgv0() {
        XCTAssertEqual(TermEnvironment.loginArgv0(shell: "/bin/zsh"), "-zsh")
        XCTAssertEqual(TermEnvironment.loginArgv0(shell: "/opt/homebrew/bin/fish"), "-fish")
    }
}
