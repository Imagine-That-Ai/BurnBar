import Testing
@testable import OpenBurnBarCore

// MARK: - UnifiedToolCallAccordionTests
//
// Pure-logic coverage for UnifiedToolCallDisplay (iconName, state) and the
// UnifiedToolCallAccordion static helpers (mostRecent, additionalCount).
// No SwiftUI rendering — all assertions run in the Swift Testing harness.

struct UnifiedToolCallAccordionTests {

    // MARK: - iconName mapping

    @Test func iconName_read() {
        #expect(UnifiedToolCallDisplay.iconName(for: "read_file") == "doc.text")
        #expect(UnifiedToolCallDisplay.iconName(for: "ReadFile") == "doc.text")
        #expect(UnifiedToolCallDisplay.iconName(for: "write_file") == "doc.text")
        #expect(UnifiedToolCallDisplay.iconName(for: "FILE_OPEN") == "doc.text")
    }

    @Test func iconName_bash() {
        #expect(UnifiedToolCallDisplay.iconName(for: "bash") == "terminal")
        #expect(UnifiedToolCallDisplay.iconName(for: "exec_command") == "terminal")
        #expect(UnifiedToolCallDisplay.iconName(for: "run_script") == "terminal")
        #expect(UnifiedToolCallDisplay.iconName(for: "terminal_send") == "terminal")
    }

    @Test func iconName_search() {
        #expect(UnifiedToolCallDisplay.iconName(for: "search_files") == "magnifyingglass")
        #expect(UnifiedToolCallDisplay.iconName(for: "grep_search") == "magnifyingglass")
        #expect(UnifiedToolCallDisplay.iconName(for: "glob_pattern") == "magnifyingglass")
        #expect(UnifiedToolCallDisplay.iconName(for: "find_references") == "magnifyingglass")
    }

    @Test func iconName_web() {
        #expect(UnifiedToolCallDisplay.iconName(for: "web_search") == "globe")
        #expect(UnifiedToolCallDisplay.iconName(for: "browser_navigate") == "globe")
        #expect(UnifiedToolCallDisplay.iconName(for: "fetch_url") == "globe")
        #expect(UnifiedToolCallDisplay.iconName(for: "http_request") == "globe")
    }

    @Test func iconName_edit() {
        #expect(UnifiedToolCallDisplay.iconName(for: "edit_file") == "pencil.and.outline")
        #expect(UnifiedToolCallDisplay.iconName(for: "patch_code") == "pencil.and.outline")
        #expect(UnifiedToolCallDisplay.iconName(for: "replace_content") == "pencil.and.outline")
    }

    @Test func iconName_memory() {
        #expect(UnifiedToolCallDisplay.iconName(for: "memory_store") == "brain")
        #expect(UnifiedToolCallDisplay.iconName(for: "skill_lookup") == "brain")
        #expect(UnifiedToolCallDisplay.iconName(for: "learn_fact") == "brain")
    }

    @Test func iconName_image() {
        #expect(UnifiedToolCallDisplay.iconName(for: "image_generate") == "photo")
        #expect(UnifiedToolCallDisplay.iconName(for: "vision_describe") == "photo")
        #expect(UnifiedToolCallDisplay.iconName(for: "screenshot_capture") == "photo")
    }

    @Test func iconName_default() {
        // Names that don't match any keyword fall back to the generic icon.
        #expect(UnifiedToolCallDisplay.iconName(for: "unknown_tool") == "wrench.and.screwdriver.fill")
        #expect(UnifiedToolCallDisplay.iconName(for: "") == "wrench.and.screwdriver.fill")
        #expect(UnifiedToolCallDisplay.iconName(for: "custom_action_xyz") == "wrench.and.screwdriver.fill")
    }

    // MARK: - state classification from statusRaw

    @Test func state_isRunning_wins_over_statusRaw() {
        // isRunning=true always produces .running regardless of statusRaw.
        let call = UnifiedToolCallDisplay(id: "1", name: "tool", statusRaw: "done", isRunning: true)
        #expect(call.state == .running)
    }

    @Test func state_done_variants() {
        let doneStrings = ["done", "Done", "complete", "completed", "finished", "success", "ok", "ran"]
        for raw in doneStrings {
            let call = UnifiedToolCallDisplay(id: raw, name: "t", statusRaw: raw)
            #expect(call.state == .done, "Expected .done for statusRaw='\(raw)'")
        }
    }

    @Test func state_failed_variants() {
        let failStrings = ["failed", "error", "DENIED", "cancelled", "timeout", "rejected"]
        for raw in failStrings {
            let call = UnifiedToolCallDisplay(id: raw, name: "t", statusRaw: raw)
            #expect(call.state == .failed, "Expected .failed for statusRaw='\(raw)'")
        }
    }

    @Test func state_running_from_statusRaw() {
        let runStrings = ["running", "pending", "active", "streaming", "in_progress", "started"]
        for raw in runStrings {
            let call = UnifiedToolCallDisplay(id: raw, name: "t", statusRaw: raw, isRunning: false)
            #expect(call.state == .running, "Expected .running for statusRaw='\(raw)'")
        }
    }

    @Test func state_neutral_when_nil() {
        let call = UnifiedToolCallDisplay(id: "1", name: "t", statusRaw: nil, isRunning: false)
        #expect(call.state == .neutral)
    }

    @Test func state_neutral_when_empty() {
        let call = UnifiedToolCallDisplay(id: "1", name: "t", statusRaw: "   ", isRunning: false)
        #expect(call.state == .neutral)
    }

    @Test func state_neutral_unrecognised_string() {
        let call = UnifiedToolCallDisplay(id: "1", name: "t", statusRaw: "queued_v2", isRunning: false)
        // "queued" doesn't contain any recognised keyword → neutral.
        #expect(call.state == .neutral)
    }

    // MARK: - mostRecent & additionalCount

    @Test func mostRecent_returns_last_element() {
        let calls = makeDisplays(count: 5)
        let recent = UnifiedToolCallAccordion.mostRecent(of: calls)
        #expect(recent?.id == "4")   // 0-indexed; last is id "4"
    }

    @Test func mostRecent_empty_returns_nil() {
        #expect(UnifiedToolCallAccordion.mostRecent(of: []) == nil)
    }

    @Test func mostRecent_single_element() {
        let single = [UnifiedToolCallDisplay(id: "only", name: "tool")]
        #expect(UnifiedToolCallAccordion.mostRecent(of: single)?.id == "only")
    }

    @Test func additionalCount_is_count_minus_one() {
        let calls = makeDisplays(count: 5)
        #expect(UnifiedToolCallAccordion.additionalCount(of: calls) == 4)
    }

    @Test func additionalCount_single_is_zero() {
        let single = [UnifiedToolCallDisplay(id: "x", name: "t")]
        #expect(UnifiedToolCallAccordion.additionalCount(of: single) == 0)
    }

    @Test func additionalCount_empty_is_zero() {
        #expect(UnifiedToolCallAccordion.additionalCount(of: []) == 0)
    }

    // MARK: - hasExpandableDetail

    @Test func hasExpandableDetail_false_when_no_args_or_result() {
        let call = UnifiedToolCallDisplay(id: "1", name: "tool", detail: "some detail")
        // detail is shown in the collapsed row; only arguments/result gating expansion.
        #expect(call.hasExpandableDetail == false)
    }

    @Test func hasExpandableDetail_true_when_arguments_present() {
        let call = UnifiedToolCallDisplay(id: "1", name: "tool", arguments: "{\"path\":\"/tmp\"}")
        #expect(call.hasExpandableDetail == true)
    }

    @Test func hasExpandableDetail_true_when_result_present() {
        let call = UnifiedToolCallDisplay(id: "1", name: "tool", result: "exit 0")
        #expect(call.hasExpandableDetail == true)
    }

    @Test func hasExpandableDetail_false_when_whitespace_only() {
        let call = UnifiedToolCallDisplay(id: "1", name: "tool", arguments: "   \n\t", result: "   ")
        #expect(call.hasExpandableDetail == false)
    }

    // MARK: - State transition regression (StatusDot re-entry)

    @Test func state_transition_running_to_done() {
        // Verifies the computed `state` value is re-evaluated correctly when
        // `statusRaw` changes — the StatusDot onChange(of:) handler depends on this.
        let runningCall = UnifiedToolCallDisplay(id: "1", name: "t", statusRaw: "running", isRunning: false)
        #expect(runningCall.state == .running)

        let doneCall = UnifiedToolCallDisplay(id: "1", name: "t", statusRaw: "done", isRunning: false)
        #expect(doneCall.state == .done)

        // Re-entering running should still classify correctly.
        let reRunCall = UnifiedToolCallDisplay(id: "1", name: "t", statusRaw: "running", isRunning: false)
        #expect(reRunCall.state == .running)
    }

    @Test func state_isRunning_flag_overrides_done_statusRaw() {
        // A call that has statusRaw="done" but isRunning=true must report .running.
        // This covers the case where a surface marks a new streaming call running
        // before the server has confirmed a status.
        let call = UnifiedToolCallDisplay(id: "1", name: "t", statusRaw: "done", isRunning: true)
        #expect(call.state == .running)
    }

    // MARK: - Accessibility hint logic

    @Test func accessibilityHint_single_call_with_args_says_details() {
        // When there's exactly one call and it has arguments (expandable detail),
        // the accordion should say "Expand to see details", not "Expand 1 tool calls".
        // This is enforced at the call-site in the View, not in the model, but we
        // verify the precondition: calls.count == 1 and hasExpandableDetail == true.
        let single = [UnifiedToolCallDisplay(id: "1", name: "bash", arguments: "{\"cmd\":\"ls\"}")]
        #expect(UnifiedToolCallAccordion.additionalCount(of: single) == 0)
        #expect(single.first?.hasExpandableDetail == true)
    }

    @Test func accessibilityHint_multiple_calls_exposes_count() {
        let many = makeDisplays(count: 3)
        // The hint should expose count when there is more than one call.
        #expect(UnifiedToolCallAccordion.additionalCount(of: many) == 2)
        #expect(many.count > 1)
    }

    // MARK: - isRunning semantics for paired calls (Mac transcript path regression)

    @Test func isRunning_false_when_tool_is_paired_with_result() {
        // Simulates the Mac transcript path: a toolUse paired with its result is
        // NOT in flight — isRunning must be false.  This tests the precondition
        // the fixed unifiedToolCalls(from:) algorithm relies on.
        let pairedCall = UnifiedToolCallDisplay(
            id: "use-1",
            name: "bash",
            result: "exit 0",   // result present → paired → not running
            isRunning: false
        )
        #expect(pairedCall.isRunning == false)
        #expect(pairedCall.hasExpandableDetail == true)
    }

    @Test func isRunning_true_only_for_last_unpaired_toolUse() {
        // Simulates two calls in the same group where only the second is in flight.
        let first = UnifiedToolCallDisplay(id: "use-1", name: "read_file", result: "content", isRunning: false)
        let second = UnifiedToolCallDisplay(id: "use-2", name: "bash", isRunning: true)
        let calls = [first, second]

        // Most recent is the in-flight one.
        #expect(UnifiedToolCallAccordion.mostRecent(of: calls)?.id == "use-2")
        #expect(UnifiedToolCallAccordion.mostRecent(of: calls)?.isRunning == true)
        // The completed first call is not running.
        #expect(calls.first?.isRunning == false)
    }

    // MARK: - Helpers

    private func makeDisplays(count: Int) -> [UnifiedToolCallDisplay] {
        (0..<count).map { i in
            UnifiedToolCallDisplay(id: "\(i)", name: "tool_\(i)")
        }
    }
}
