#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import SwiftUI
import OpenBurnBarComputerUseCore

/// Sheet for adding a Trusted-mode scope rule.
///
/// The editor stays pure SwiftUI and validates through
/// `ComputerUseScopeMatcher`, so the safety rule is identical to the
/// dispatcher: user allow-rules cannot pretend to unlock a built-in deny.
struct ComputerUseScopeRuleEditor: View {
    enum RuleKind: String, CaseIterable, Identifiable {
        case urlPrefix = "URL prefix"
        case bundleId = "Bundle ID"
        case windowTitleRegex = "Window title"

        var id: String { rawValue }
    }

    let builtInDenies: [ComputerUseScopeRule]
    let currentContext: ComputerUseScopeContext
    let onSave: (ComputerUseScopeRule) -> Void
    let onCancel: () -> Void

    @State private var ruleKind: RuleKind = .urlPrefix
    @State private var label = ""
    @State private var value = ""
    @State private var actionBudget = 50

    private let matcher = ComputerUseScopeMatcher()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Picker("Rule type", selection: $ruleKind) {
                ForEach(RuleKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Label", text: $label)
                TextField(valuePlaceholder, text: $value)
                Stepper("Trusted budget: \(actionBudget) actions", value: $actionBudget, in: 1...50)
            }
            .textFieldStyle(.roundedBorder)

            preview

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            Spacer()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Rule") {
                    onSave(makeRule())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
        }
        .padding(24)
        .frame(width: 500, height: 430)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add Scope Rule")
                .font(.system(size: 20, weight: .semibold))
            Text("Trusted mode can run without per-action approval only inside these boundaries.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current context preview")
                .font(.system(size: 12, weight: .semibold))
            row("URL", currentContext.url ?? "Unknown")
            row("Bundle", currentContext.bundleId ?? "Unknown")
            row("Window", currentContext.windowTitle ?? "Unknown")
            row("Effect", previewOutcome)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
    }

    private var valuePlaceholder: String {
        switch ruleKind {
        case .urlPrefix: return "https://github.com/openai/"
        case .bundleId: return "com.apple.Safari or com.company.*"
        case .windowTitleRegex: return "Pull Request|Issue"
        }
    }

    private var previewOutcome: String {
        guard validationMessage == nil else { return "Not saved" }
        switch matcher.evaluate(rules: builtInDenies + [makeRule()], context: currentContext) {
        case .allowed: return "Allowed by this rule"
        case .denied: return "Blocked by built-in deny"
        case .notMatched: return "No match for current window"
        }
    }

    private var validationMessage: String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a \(ruleKind.rawValue.lowercased())." }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a label." }
        if ruleKind == .windowTitleRegex,
           (try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])) == nil {
            return "Window-title regex is invalid."
        }
        let contexts = [currentContext, makeRuleSampleContext(value: trimmed)]
        if matcher.overlapsBuiltInDeny(
            proposed: makeRule(),
            builtInDenies: builtInDenies,
            sampleContexts: contexts
        ) {
            return "This allow rule overlaps a built-in deny region."
        }
        return nil
    }

    private func makeRule() -> ComputerUseScopeRule {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ComputerUseScopeRule(
            effect: .allow,
            origin: .user,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            urlPrefix: ruleKind == .urlPrefix ? trimmed : nil,
            bundleId: ruleKind == .bundleId ? trimmed : nil,
            windowTitleRegex: ruleKind == .windowTitleRegex ? trimmed : nil,
            actionBudget: actionBudget,
            expiresAt: Calendar.current.date(byAdding: .hour, value: 24, to: Date())
        )
    }

    private func makeRuleSampleContext(value: String) -> ComputerUseScopeContext {
        switch ruleKind {
        case .urlPrefix:
            return ComputerUseScopeContext(url: value)
        case .bundleId:
            return ComputerUseScopeContext(bundleId: value.replacingOccurrences(of: "*", with: "sample"))
        case .windowTitleRegex:
            return ComputerUseScopeContext(windowTitle: value)
        }
    }
}
#endif
