# iPadOS Development Research Report
## Porting macOS SwiftUI Apps to iPadOS (2025-2026)

**Date:** 2026-05-02  
**Prepared for:** OpenBurnBar / Factory Droid  
**Scope:** macOS-to-iPadOS SwiftUI porting, iPadOS 18-26 capabilities, limitations, Firebase, App Store requirements

---

## 1. Best Practices for Bringing a macOS SwiftUI App to iPadOS

### The Multiplatform Strategy

SwiftUI's promise of "write once, run everywhere" is real for basic UI, but real products require architectural planning. The recommended approach in 2025-2026 is:

#### Shared-Code Architecture
- **Use a single app target** with platform conditional compilation (`#if os(macOS)` / `#if os(iOS)`) via Xcode's multiplatform app template.
- **Extract platform-agnostic logic** into a shared framework or Swift Package (e.g. `OpenBurnBarCore` pattern already used in the codebase).
- **Separate platform-specific UI** into platform-specific files or `@ViewBuilder` branches:
  ```swift
  @ViewBuilder
  var settingsView: some View {
      #if os(macOS)
          SettingsPaneMac()
      #else
          SettingsPanePad()
      #endif
  }
  ```
- **Use `NavigationSplitView`** — it adapts natively across macOS (3-column), iPad (2-3 column), and iPhone (stacked). This is the single most important view component for a macOS-to-iPadOS port.

#### Adaptive UI Patterns
- Use `@Environment(\.horizontalSizeClass)` and `@Environment(\.verticalSizeClass)` to branch layout logic.
- Use `UIScreen.main.bounds` sparingly; prefer geometry readers and size classes.
- SF Symbols, colors, and typography scale automatically when using system APIs.

#### Key Apple Resources
- **Apple Docs:** [Configuring a multiplatform app](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-a)
- **Apple Tutorial:** [Food Truck: Building a SwiftUI multiplatform app](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app) — canonical reference for single-codebase Mac+iPad+iPhone apps.
- **WWDC 2022/2025 videos:** "Use Xcode to develop a multiplatform app" and "What's new in SwiftUI" (WWDC25 session #256).

#### Practical Porting Steps
1. Audit all `AppKit` imports — replace with `UIKit` or pure SwiftUI.
2. Audit all `NSApplication`, `NSWindow`, `NSStatusBar` usage — these have no iPad equivalents.
3. Replace `NSColor` dynamic providers with `Color` adaptive extensions (already done in OpenBurnBar's `ColorAdaptive.swift`).
4. Replace file-system-direct-access patterns with `UIDocumentPickerViewController` or `FileProvider`.
5. Replace `Process` / `NSTask` CLI spawning with network-based APIs or in-process Swift code.

---

## 2. iPadOS-Specific UI Patterns and Capabilities (iPadOS 18–26)

### iPadOS 26 — The Big Leap (WWDC 2025)

iPadOS 26 (shipping late 2025 / broadly available 2026) represents the most significant iPadOS update for developers since the platform's inception. Key changes:

| Feature | macOS Equivalent | Developer Impact |
|---------|------------------|------------------|
| **True Windowing System** | macOS window management | Apps can spawn resizable, movable windows. Stage Manager is now the *only* multitasking model; Split View and Slide Over are removed. |
| **Menu Bar** | NSMenu / menu bar | Apps can declare top-level menus that appear in a macOS-style menu bar on iPad (with pointer/keyboard attached). |
| **Pointer / Cursor** | Mouse/trackpad | Full pointer support with hover, right-click, and cursor customization. |
| **Liquid Glass** | macOS 26 design | New translucent, glossy design language systemwide. SwiftUI gains `.glassEffect()` API. |
| **Window Controls API** | `NSWindow` controls | New APIs for minimize, maximize, close buttons; window chrome customization. |
| **Stage Manager (exclusive)** | Spaces / Mission Control | No more Split View/Slide Over. Apps must design for Stage Manager window sizing. |

### Stage Manager & Multitasking
- **Removed:** Split View and Slide Over (iPadOS 26+).
- **New behavior:** Users resize and position windows freely, closer to macOS Spaces.
- **Developer requirement:** Apps must support a wide range of sizes. SwiftUI's `@Environment(\.horizontalSizeClass)` becomes essential.
- External display support has expanded — windows can be moved to external monitors independently.

### Pointer & Keyboard Support
- iPadOS 16+ already supports full pointer interactions (`UIPointerInteraction`).
- iPadOS 26 deepens this: hover states, cursor shapes, and secondary-click context menus behave like macOS.
- If your macOS app relies heavily on hover/指针 interactions, the iPadOS port will feel natural on iPad with Magic Keyboard.

---

## 3. What CANNOT Be Done on iPadOS vs macOS

This is the critical section for OpenBurnBar, which is fundamentally a **menu bar macOS app** with CLI integrations.

### Impossible / Heavily Restricted

| macOS Feature | iPadOS Status | Workaround |
|---------------|---------------|------------|
| **Menu Bar Extra (`NSStatusBar`)** | ❌ Not possible | iPad has no persistent menu bar extras. The app must be a **regular foreground app**. iPadOS 26 adds an *app-specific* menu bar, but no system-tray equivalents. |
| **Spawning CLI Subprocesses (`Process`/`NSTask`)** | ❌ Sandboxed out | iPadOS apps cannot spawn arbitrary shell processes. Must replace with: in-process Swift libraries, HTTP APIs, or JavaScriptCore. |
| **Full File System Access** | ❌ Sandboxed | Apps are restricted to their container. To access user files, use `UIDocumentPickerViewController` or implement a `FileProvider` extension. Security-scoped bookmarks required. |
| **Background Daemons / Always-On Processes** | ❌ Not possible | No `launchd` agents. Limited to: `BGTaskScheduler` (background refresh, processing), `BGContinuedProcessingTask` (new iOS 26), push notifications, or Live Activities. |
| **`NSWorkspace` / global system events** | ❌ Not possible | Cannot monitor global file system changes, app launches, etc. |
| **`NSWindow` chrome customization** | ⚠️ Partial | iPadOS 26 introduces new window controls, but still more constrained than macOS `NSWindow` styling. |
| **AppKit-only APIs** | ❌ Not available | Must replace with UIKit or SwiftUI. No `NSColorSpace`, `NSBezierPath`, `NSImageRep`, etc. |
| **Unix domain sockets (arbitrary)** | ⚠️ Restricted | Can use network sockets (`localhost`) if declared in entitlements, but not arbitrary file-based sockets outside container. |
| **Keychain sharing across apps** | ⚠️ Limited | Keychain access groups work but are more constrained than macOS. |

### What Works Great on Both

| Feature | macOS | iPadOS |
|---------|-------|--------|
| SwiftUI (`NavigationSplitView`, `List`, `Form`) | ✅ | ✅ |
| SwiftData / Core Data | ✅ | ✅ |
| Network requests (`URLSession`, WebSocket) | ✅ | ✅ |
| Firebase SDK | ✅ | ✅ (same `firebase-ios-sdk`) |
| Combine / async-await | ✅ | ✅ |
| Widgets | ✅ (Notification Center) | ✅ (Home Screen) |
| Live Activities | N/A | ✅ |
| Handoff / Continuity | ✅ | ✅ |
| Local SQLite databases | ✅ | ✅ (in container) |

---

## 4. Handling macOS-Specific Features on iPadOS

### Replacing the Menu Bar App Pattern

OpenBurnBar is a **menu bar utility** on macOS. On iPad, this pattern fundamentally does not exist. Here are the replacement strategies:

#### Option A: Foreground Dashboard App (Recommended)
- The app launches into a **dashboard** view — essentially the existing popover content expanded to a full window.
- Use `NavigationSplitView` with a compact sidebar for providers/settings and a detail view for the dashboard.
- This is the pattern used by apps like **Stats** (though Stats is macOS-only, many monitoring apps on iPad use this design).

#### Option B: Widget + Live Activity
- For **at-a-glance token usage**, build a Home Screen widget (iOS 14+) or Live Activity (iOS 16.1+).
- Widgets are the closest iPad equivalent to menu bar glanceability.
- Live Activities are particularly powerful for showing real-time spend data in the Dynamic Island / Lock Screen (on supported devices) or in the StandBy widget stack.

#### Option C: Background Refresh + Notifications
- Use `BGTaskScheduler` (or the new `BGContinuedProcessingTask` in iPadOS 26) to periodically sync token usage data from Firebase.
- Push local notifications when thresholds are exceeded.

#### Option D: Shortcuts App Integration (Siri Shortcuts)
- Provide Shortcuts actions so users can query token usage via Siri or automation.
- This approximates the "quick access" nature of a menu bar app.

### Replacing CLI Process Spawning

OpenBurnBar spawns CLI tools (e.g., `codex`, `claude`) to gather usage data. On iPad:

| Strategy | Feasibility | Notes |
|----------|-------------|-------|
| **HTTP API to a companion server** | ✅ High | Replace CLI calls with HTTP calls to a backend (Firebase Cloud Functions, or a local companion app on Mac). |
| **In-process Swift parsing** | ✅ Medium | If the data source is logs or JSON files, parse them directly in Swift. |
| **JavaScriptCore** | ⚠️ Medium | Can run JS-based tools in-app, but not arbitrary system binaries. |
| **SwiftWasm / embedded toolchain** | ⚠️ Low | Experimental; not practical for a production app. |

**Recommendation:** For a companion iPad app to OpenBurnBar, the cleanest architecture is a **Firebase-backed sync model**:
- macOS app (menu bar) pushes token usage data to Firestore.
- iPad app reads from the same Firestore collection.
- iPad app never needs to spawn processes; it just displays cloud-synced data.

This is exactly the architecture OpenBurnBar already appears to be building (based on the `mobile cloud sync companion flow` commit visible in context).

### Replacing File System Access

- Use `UIDocumentPickerViewController` for user-initiated file access.
- Implement a `FileProvider` extension if your app manages a document type (e.g., `.burnbar` analytics exports).
- Store app-generated data in the app's sandbox container (`FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)`).

---

## 5. Firebase Support on iPadOS

### Current State (2025-2026)

Firebase uses the **same SDK** for iOS and iPadOS: `firebase-ios-sdk`.

| Service | iPadOS Support | Notes |
|---------|---------------|-------|
| **Firebase Auth** | ✅ Full | Same APIs as macOS/iOS. Supports Sign in with Apple, Google, email/password, anonymous. |
| **Cloud Firestore** | ✅ Full | Real-time sync works identically. Offline persistence enabled by default. |
| **Firebase Cloud Functions** | ✅ Full | Client SDK for calling functions works the same. |
| **Firebase Analytics** | ✅ Full | Automatic screen tracking; event logging identical. |
| **Firebase Crashlytics** | ✅ Full | iPadOS crash reporting is supported. |
| **Firebase App Check** | ✅ Full | RequiredCloud Functions / Firestore security rules since late 2024. |
| **Firebase Cloud Messaging** | ✅ Full | Push notifications work on iPad same as iPhone. |
| **Firebase Performance Monitoring** | ✅ Full | |
| **Firebase Remote Config** | ✅ Full | |

### Installation
- **Swift Package Manager** is the recommended method (CocoaPods is deprecated as of 2025-2026).
- Configure `GoogleService-Info.plist` in the iPad target just like iOS/macOS.

### Gotchas
- **App Check:** If your macOS app already uses App Check (required for Cloud Functions + Firestore), the iPad app must also register an App Attest provider. On iPadOS, App Attest uses the Secure Enclave.
- **Keychain sharing:** If using Firebase Auth across macOS and iPad (via iCloud Keychain), the user stays signed in. This is automatic if the same Firebase project and Team ID are used.

**Verdict:** Firebase is a *non-issue* for the port. The same configuration, SDK, and security model apply.

---

## 6. SwiftUI on iPadOS: NavigationSplitView, UIScene, and Window Management

### NavigationSplitView

`NavigationSplitView` is the **cornerstone** of a macOS-to-iPadOS SwiftUI port. It is the modern replacement for `NavigationView` and handles adaptive column behavior automatically:

```swift
NavigationSplitView {
    SidebarView()   // Column 1
} content: {
    ContentView()   // Column 2
} detail: {
    DetailView()    // Column 3
}
```

| Platform | Behavior |
|----------|----------|
| **macOS** | Three-column layout by default. Collapsible sidebars. |
| **iPad (regular)** | Three-column in landscape; two-column in portrait via sidebar toggle. |
| **iPad (compact)** | Stacks into a single `NavigationStack`. |
| **iPhone** | Single `NavigationStack`. |

**Key modifiers:**
- `.navigationSplitViewStyle(.balanced)` — balanced column widths.
- `.navigationSplitViewColumnWidth(min:ideal:max:)` — control sizing.

### UIScene / UIWindowScene

On iPad, each window is a `UIScene` (specifically `UIWindowScene`). In SwiftUI, you manage this via:

- **`WindowGroup`** — default multi-window support on iPadOS.
- **`@Environment(\.openWindow)`** — open new windows programmatically (macOS 13+, iPadOS 16+).
- **`@Environment(\.dismissWindow)`** — close windows.

In iPadOS 26, Apple expanded window management APIs significantly:
- New **Window Controls** APIs allow apps to control minimize, maximize, and close behavior.
- Apps can now programmatically resize and reposition windows within the Stage Manager workspace.

### Multi-Window Support

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        
        // Secondary window for a specific feature
        Window("Token Detail", id: "token-detail") {
            TokenDetailView()
        }
    }
}
```

On iPadOS 16+, users can create multiple instances of `WindowGroup` windows via the app switcher or Stage Manager.

### Liquid Glass (iPadOS 26)

- SwiftUI gains `.glassEffect()` modifier.
- System buttons, toolbars, and navigation bars adopt translucent glass styling automatically.
- **Developer action:** Review custom UI components to ensure they aren't fighting against the new translucent system chrome. Use system materials (`.ultraThinMaterial`, `.thinMaterial`) which now map to Liquid Glass automatically.

---

## 7. App Store Requirements for iPad Apps in 2026 (iPadOS 18+)

### Minimum SDK Requirements

As of **April 2026**, Apple requires:

- **Xcode 16 or later**
- **SDK minimum:** iOS 18, iPadOS 18, tvOS 18, visionOS 2, watchOS 11

Apps built with older SDKs will be rejected from App Store Connect.

### iPad-Specific Requirements

| Requirement | Rule |
|-------------|------|
| **Universal app** | If submitting for iPhone, you must also support iPad (unless specifically opting out for iPhone-only). |
| **All orientations** | iPad apps must support all four orientations (portrait, upside-down, landscape left/right). |
| **Split View / Stage Manager** | Apps must gracefully handle being resized in Split View and Stage Manager. Cannot require full-screen. |
| **Pointer support** | Non-game iPad apps should have full pointer interaction support (hover, cursor, right-click). |
| **Keyboard support** | If the app supports text input, it must support external hardware keyboards (shortcut keys, Tab navigation). |

### Review Guidelines (2026)
- Apps must use current design patterns (Liquid Glass on iPadOS 26+ is expected but not strictly enforced for non-system apps yet).
- Background execution must use approved APIs (`BGTaskScheduler`, push, `BGContinuedProcessingTask`); no "keep-alive" hacks.
- File access must use the Document Picker or FileProvider APIs where applicable.

---

## 8. Notable Examples and Guides for macOS-to-iPadOS Ports

### Official Apple Examples

1. **Food Truck** — [Apple Developer Tutorial](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app)
   - Single codebase for Mac, iPad, iPhone.
   - Demonstrates `NavigationSplitView`, shared models, and adaptive UI.
   - **This is the best starting template for OpenBurnBar's iPad port.**

2. **Scrumdinger** — Apple tutorial (updated for SwiftData)
   - Multiplatform with shared SwiftData models.

### Community Guides

3. **"SwiftUI Multi-Platform Architecture" (Dev.to, 2026)**
   - Deep dive into navigation challenges across platforms.
   - Recommendations on where to use `#if os()` vs. separate files.

4. **"Building a Unified Multiplatform Architecture with SwiftUI" (Medium, 2025)**
   - Design adaptive Apple apps with unified interfaces.

5. **TrozWare — "SwiftUI for Mac 2025"**
   - macOS-specific SwiftUI patterns, useful for recognizing what needs to change.

6. **JuniperPhoton — "SwiftUI 2025: What's Fixed, What's Not"**
   - Current state of SwiftUI robustness. Notes that `NavigationSplitView` and multi-window are production-ready in 2025.

### Real-World macOS → iPad Port Examples

While dedicated "macOS menu bar → iPad" case studies are rare, comparable porting strategies include:
- **Apple's own apps** (Notes, Reminders, Photos) are multiplatform SwiftUI with `NavigationSplitView`.
- **Developer tool apps** (e.g., **Playgrounds**, **TestFlight**) demonstrate how complex tools adapt to iPad.
- **Concept:** Raycast (macOS launcher) has no iPad port because of the menu bar dependency, illustrating the fundamental pattern shift required.

---

## Summary & Key Recommendations for OpenBurnBar

### The Core Challenge

OpenBurnBar is architecturally a **macOS menu bar utility with CLI integrations**. Porting to iPadOS requires a **product rethink**, not just a UI port:

1. **Menu bar → Full app:** The iPad app must be a foreground dashboard, not a background utility.
2. **CLI spawning → Cloud sync:** The iPad cannot spawn `codex`/`claude` processes. Use the existing Firebase sync pipeline to display data from the macOS app.
3. **Popover → Window:** The 340px popover becomes a full window using `NavigationSplitView`.
4. **Settings → Full settings:** The `NavigationSplitView`-based settings window should translate directly to iPad.

### Architecture Recommendation

```
┌─────────────────────────────────────────────┐
│           Shared Core (Swift Package)       │
│  - Data models (TokenUsage, Provider, etc.) │
│  - Firebase services                        │
│  - Design system (Colors, Typography)       │
│  - ViewModels (where platform-agnostic)     │
└─────────────────────────────────────────────┘
           │                │
    ┌──────▼──────┐  ┌─────▼──────┐
    │   macOS     │  │   iPadOS   │
    │  (Menu Bar) │  │ (Dashboard)│
    └─────────────┘  └────────────┘
```

### Migration Priority

| Priority | Task | Effort |
|----------|------|--------|
| **P0** | Create iPad app target in Xcode project | Low |
| **P0** | Extract shared code into `OpenBurnBarCore` | Medium |
| **P1** | Replace `NSStatusBar`/`NSPopover` with `WindowGroup` + `NavigationSplitView` | Medium |
| **P1** | Replace CLI spawning with Firebase-synced data reads | High |
| **P2** | Add iPad-specific interactions (pointer hover, keyboard shortcuts) | Medium |
| **P2** | Add Home Screen widget for glanceable token usage | Medium |
| **P3** | Adopt Liquid Glass materials (iPadOS 26) | Low |

### No-Go Items for iPad

- **Menu bar extra / status item:** Cannot be replicated.
- **Local CLI bridge (`CLIBridge`):** Must be replaced with cloud-sync or a companion Mac daemon.
- **Arbitrary file system monitoring:** Must use Document Picker for user files.
- **Unix socket to local daemon (`localhost:8642` Hermes bridge):** Can work if using TCP/IP instead of file-based sockets, but the daemon must run elsewhere (on Mac or a server).

---

## Sources

- Apple Developer Documentation: [Configuring a multiplatform app](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-a)
- Apple Developer Tutorial: [Food Truck](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app)
- Apple: [iPadOS 26 Windowing, Menu Bar, Pointer](https://www.apple.com/newsroom/2025/06/ipados-26-introduces-powerful-new-feat...)
- MacRumors: [Windowing, Menu Bar, and Pointer Come to iPadOS](https://www.macrumors.com/2025/06/09/windowing-menu-bar-and-pointer-come-to-i...)
- JuniperPhoton: [SwiftUI 2025: What's Fixed, What's Not](https://juniperphoton.substack.com/p/swiftui-2025-whats-fixed-whats-not)
- 9to5Mac: [iPadOS 26 removes Split View and Slide Over](https://9to5mac.com/2025/06/09/psa-ipados-26-removes-split-view-and-slide-ove...)
- Apple: [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- Firebase: [Firebase for Apple platforms](https://firebase.google.com/docs/ios/learn-more)
- SlatePad: [iPadOS 26 Multitasking Guide](https://slatepad.org/2026/01/24/ipados-26-multitasking-guide/)
- Apple Developer: [NavigationSplitView](https://developer.apple.com/documentation/SwiftUI/NavigationSplitView)
- WWDC 2025: [What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/)
