import SwiftUI

// MARK: - Navigation Settings
//
// The tab-bar editor: reorder, remove, add, and configure the items in the
// bottom navigation tray, plus the swipe-between-tabs toggle. The same layout
// drives the iPad sidebar's primary section, so this page is the one place
// navigation is shaped on every device class.
//
// Rules enforced here (and re-enforced by `AuroraNavItem.sanitized` on every
// persist, so a bad edit can never brick the tray):
//   • `.you` cannot be removed — it hosts Settings, including this page.
//   • Only the AI Inbox can appear more than once (per-filter presets make
//     duplicates meaningful).
//   • Between `AuroraNavItem.minItems` and `.maxItems` tabs.

struct NavigationSettingsView: View {
    @StateObject private var customization = AppCustomization.shared

    var body: some View {
        Form {
            tabsSection
            addSection
            gesturesSection
        }
        .navigationTitle("Navigation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    // MARK: - Current layout

    private var tabsSection: some View {
        Section {
            ForEach(customization.navItems) { item in
                tabRow(item)
                    .deleteDisabled(
                        AuroraNavItem.isRemovable(item, in: customization.navItems) == false
                    )
            }
            .onMove { indices, offset in
                var items = customization.navItems
                items.move(fromOffsets: indices, toOffset: offset)
                customization.navItems = items
            }
            .onDelete { indices in
                var items = customization.navItems
                items.remove(atOffsets: indices)
                customization.navItems = items
            }
        } header: {
            Text("Tab Bar")
                .settingsAnchor(SettingsAnchor.navigationTabBar)
        } footer: {
            Text("Drag to reorder. Swipe a row to remove it. The tab bar holds \(AuroraNavItem.minItems)–\(AuroraNavItem.maxItems) tabs; the Store tab stays put because Settings lives there.")
        }
    }

    private func tabRow(_ item: AuroraNavItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(item.kind.accent)
                    .frame(width: 26, height: 26)
                Image(systemName: item.kind.asAppDestination.fallbackIcon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(item.displayLabel)
                .font(MobileTheme.Typography.body)

            Spacer()

            if item.kind == .inbox {
                inboxPresetMenu(for: item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayLabel)
    }

    /// Per-instance inbox filter preset. "Follow last used" (nil) keeps the
    /// shared store's current filter; a concrete preset re-applies itself each
    /// time that tab is selected — the point of keeping several inbox tabs.
    private func inboxPresetMenu(for item: AuroraNavItem) -> some View {
        Menu {
            Button("Follow last used") { setPreset(nil, for: item) }
            ForEach(AIInboxStore.Filter.allCases) { filter in
                Button(filter.title) { setPreset(filter, for: item) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(item.inboxFilterPreset?.title ?? "Follow last used")
                    .font(MobileTheme.Typography.tiny)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .accessibilityLabel("Inbox filter preset: \(item.inboxFilterPreset?.title ?? "follow last used")")
    }

    private func setPreset(_ filter: AIInboxStore.Filter?, for item: AuroraNavItem) {
        var items = customization.navItems
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].inboxFilter = filter?.rawValue
        customization.navItems = items
    }

    // MARK: - Add

    private var addSection: some View {
        Section {
            ForEach(addableKinds, id: \.self) { kind in
                Button {
                    HapticBus.toggle()
                    var items = customization.navItems
                    // A second inbox needs a fresh instance id; single-instance
                    // kinds reuse their canonical id so re-adding a removed tab
                    // restores the exact item the smoke tests address.
                    let item = customization.navItems.contains(where: { $0.kind == kind })
                        ? AuroraNavItem(kind: kind)
                        : AuroraNavItem.canonical(kind)
                    items.append(item)
                    customization.navItems = items
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(MobileTheme.success)
                        Text(kind.label)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                }
            }
            if addableKinds.isEmpty {
                Text(atCapacity ? "The tab bar is full." : "Every destination is already in the tab bar.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        } header: {
            Text("Add Tab")
        } footer: {
            Text("The AI Inbox can be added more than once — pin each copy to a different filter to jump straight to what needs attention.")
        }
    }

    private var atCapacity: Bool {
        customization.navItems.count >= AuroraNavItem.maxItems
    }

    private var addableKinds: [AuroraNavDestination] {
        guard atCapacity == false else { return [] }
        let present = Set(customization.navItems.map(\.kind))
        return AuroraNavDestination.allCases.filter { kind in
            AuroraNavItem.allowsMultipleInstances(kind) || present.contains(kind) == false
        }
    }

    // MARK: - Gestures

    private var gesturesSection: some View {
        Section {
            Toggle(isOn: $customization.isSwipeNavigationEnabled) {
                SettingsLabel(
                    icon: "hand.draw.fill",
                    color: MobileTheme.whimsy,
                    title: "Swipe between tabs"
                )
            }
            .tint(MobileTheme.ember)
            .settingsAnchor(SettingsAnchor.navigationSwipe)
        } header: {
            Text("Gestures")
        } footer: {
            Text("Swipe left or right anywhere on a tab's content to move to the neighboring tab.")
        }
    }
}

#Preview {
    NavigationStack {
        NavigationSettingsView()
    }
}
