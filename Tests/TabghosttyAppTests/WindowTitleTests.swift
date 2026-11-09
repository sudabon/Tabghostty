import Testing
@testable import TabghosttyApp

/// spec: app-shell「Main window」のタイトル。
@Suite struct WindowTitleTests {
    private let home = "/Users/me"

    // Scenario: Title follows directory
    @Test func lastPathComponent() {
        #expect(WindowTitle.make(cwd: "/Users/me/projects/app", home: home) == "app — Tabghostty")
    }

    @Test func trailingSlashIsIgnored() {
        #expect(WindowTitle.make(cwd: "/Users/me/projects/app/", home: home) == "app — Tabghostty")
        #expect(WindowTitle.make(cwd: "/Users/me/projects/app//", home: home) == "app — Tabghostty")
    }

    @Test func homeAndEmptyAreTilde() {
        #expect(WindowTitle.make(cwd: "/Users/me", home: home) == "~ — Tabghostty")
        #expect(WindowTitle.make(cwd: "/Users/me/", home: home) == "~ — Tabghostty")
        #expect(WindowTitle.make(cwd: "", home: home) == "~ — Tabghostty")
        #expect(WindowTitle.make(cwd: "/Users/me/projects", home: "/Users/me/") == "projects — Tabghostty")
    }

    @Test func rootIsSlash() {
        #expect(WindowTitle.make(cwd: "/", home: home) == "/ — Tabghostty")
        #expect(WindowTitle.make(cwd: "//", home: home) == "/ — Tabghostty")
    }

    @Test func noActiveSession() {
        #expect(WindowTitle.make(cwd: nil, home: home) == "Tabghostty")
    }
}
