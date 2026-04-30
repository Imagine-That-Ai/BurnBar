import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - DashboardWorkspaceNavStrip

@MainActor
final class DashboardWorkspaceNavStripTests: XCTestCase {

    func test_rendersFourNavButtons() throws {
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { _ in }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 4, "Should render 4 workspace nav buttons")
    }

    func test_databaseButtonNavigatesToDatabase() throws {
        var navigatedRoute: DashboardMainRoute?
        let view = DashboardWorkspaceNavStrip(
            currentRoute: .overview,
            onNavigate: { navigatedRoute = $0 }
        )
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        try buttons[0].tap()
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
        try buttons[1].tap()
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
        try buttons[2].tap()
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
        try buttons[3].tap()
        XCTAssertEqual(navigatedRoute, .sessionLogs)
    }
}
