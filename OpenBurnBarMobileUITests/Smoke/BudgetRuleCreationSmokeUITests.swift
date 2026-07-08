import XCTest

/// Flow 4 — Create a budget rule through the UI and assert it appears in the
/// list.
///
/// Path: Insights tab → "Budgets" segment → Budget Center → "Add" menu →
/// "Global Rule" → editor sheet (label filled, default $50 amount) → Save.
/// The rule is persisted by the local `BudgetRulesStore` (device-local, **not**
/// Firestore), and the created rule's label is asserted to render on a card.
@MainActor
final class BudgetRuleCreationSmokeUITests: SmokeUITestCase {

    func testCreateGlobalBudgetRuleAppearsInList() {
        let app = launchSeededApp()

        selectAuroraTab("insights", in: app)

        // Switch to the Budgets section of the Insights tab.
        let budgetsSegment = buttonByIdentifierOrLabel(
            "insights.section.budgets", label: "Budgets", in: app, timeout: 20
        )
        XCTAssertTrue(
            budgetsSegment.waitForExistence(timeout: 20),
            "Budgets section control not found on the Insights tab.\n\(app.debugDescription)"
        )
        budgetsSegment.tap()

        // With no rules yet, Budget Center shows an empty state whose
        // "Add Global Limit" CTA opens the editor directly. (Once rules exist,
        // the same editor is reached via the "Add" menu → "Global Rule".)
        let emptyStateCTA = app.buttons["budget.addGlobalLimit"].firstMatch
        if scrollToHittable(emptyStateCTA, in: app) {
            emptyStateCTA.tap()
        } else {
            let addMenu = buttonByIdentifierOrLabel("budget.addMenu", label: "Add", in: app, timeout: 20)
            XCTAssertTrue(
                scrollToHittable(addMenu, in: app),
                "Neither the empty-state CTA nor the 'Add' menu was reachable.\n\(app.debugDescription)"
            )
            addMenu.tap()
            let globalRule = buttonByIdentifierOrLabel(
                "budget.addGlobalRule", label: "Global Rule", in: app, timeout: 10
            )
            XCTAssertTrue(
                globalRule.waitForExistence(timeout: 10),
                "Global Rule menu item not found.\n\(app.debugDescription)"
            )
            globalRule.tap()
        }

        // The editor sheet for a brand-new rule.
        XCTAssertTrue(
            app.navigationBars["New Budget Rule"].waitForExistence(timeout: 15),
            "Budget rule editor did not appear.\n\(app.debugDescription)"
        )

        let uniqueLabel = "UITest Global Cap 4271"
        let labelField = app.textFields["budget.editor.label"].firstMatch
        XCTAssertTrue(
            labelField.waitForExistence(timeout: 10),
            "Budget rule label field not found.\n\(app.debugDescription)"
        )
        labelField.tap()
        labelField.typeText(uniqueLabel)

        // A global rule defaults to a $50 amount, so Save is enabled.
        let save = app.buttons["budget.editor.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save button not found.")
        XCTAssertTrue(
            save.isEnabled,
            "Save should be enabled for a global rule with the default amount.\n\(app.debugDescription)"
        )
        save.tap()

        // The new rule renders on a card in the list, identified by its label.
        let ruleCardLabel = app.staticTexts[uniqueLabel].firstMatch
        if !ruleCardLabel.waitForExistence(timeout: 15) {
            _ = scrollToHittable(ruleCardLabel, in: app)
        }
        XCTAssertTrue(
            ruleCardLabel.exists,
            "Created budget rule '\(uniqueLabel)' did not appear in the list.\n\(app.debugDescription)"
        )
    }
}
