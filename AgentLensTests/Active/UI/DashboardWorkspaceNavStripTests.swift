import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - DashboardWorkspaceNavStrip

@MainActor
final class DashboardWorkspaceNavStripTests: XCTestCase {

    func test_rendersSixNavButtons() throws {
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { _ in }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 6, "Should render 6 workspace nav buttons (chat + quota + database + projects + missions + session logs)")
    }

    func test_chatButtonNavigatesToChat() throws {
        var navigatedRoute: DashboardMainRoute?
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        try buttons[0].tap()
        XCTAssertEqual(navigatedRoute, .chat)
    }

    func test_quotaButtonNavigatesToQuota() throws {
        var navigatedRoute: DashboardMainRoute?
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        try buttons[1].tap()
        XCTAssertEqual(navigatedRoute, .quota)
    }

    func test_databaseButtonNavigatesToDatabase() throws {
        var navigatedRoute: DashboardMainRoute?
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        try buttons[2].tap()
        XCTAssertEqual(navigatedRoute, .database)
    }

    func test_projectsButtonNavigatesToProjects() throws {
        var navigatedRoute: DashboardMainRoute?
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        try buttons[3].tap()
        XCTAssertEqual(navigatedRoute, .projects)
    }

    func test_missionsButtonNavigatesToMissions() throws {
        var navigatedRoute: DashboardMainRoute?
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        try buttons[4].tap()
        XCTAssertEqual(navigatedRoute, .missions)
    }

    func test_sessionLogsButtonNavigatesToSessionLogs() throws {
        var navigatedRoute: DashboardMainRoute?
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        try buttons[5].tap()
        XCTAssertEqual(navigatedRoute, .sessionLogs)
    }
}
