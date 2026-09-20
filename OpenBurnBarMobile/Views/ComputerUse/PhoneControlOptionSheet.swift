#if canImport(SwiftUI) && canImport(UIKit)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import OpenBurnBarComputerUseCore

struct PhoneControlOptionSheet: View {
    let snapshot: AgentWatchSessionSnapshot
    let onTrustMode: (ComputerUseTrustMode) -> Void
    let onType: (String) -> Void
    let onShortcut: (String, [String]) -> Void
    let onPanic: () -> Void
    var onSendWorkspaceFile: ((URL) -> Void)? = nil
    var onFreezeFrame: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var textToType = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isShowingFileImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section("Take over") {
                    TextField("Text to type", text: $textToType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let trimmed = textToType.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { return }
                        onType(trimmed)
                        textToType = ""
                        dismiss()
                    } label: {
                        Label("Type text", systemImage: "keyboard")
                    }
                    .disabled(textToType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        onShortcut("Return", [])
                        dismiss()
                    } label: {
                        Label("Return", systemImage: "return")
                    }

                    Button {
                        onShortcut("Escape", [])
                        dismiss()
                    } label: {
                        Label("Escape", systemImage: "escape")
                    }

                    Button {
                        onShortcut("L", ["command"])
                        dismiss()
                    } label: {
                        Label("Command-L", systemImage: "link")
                    }
                }

                Section("Mac workspace") {
                    if onSendWorkspaceFile != nil {
                        PhotosPicker(selection: $photoPickerItem, matching: .images) {
                            Label("Send photo or camera roll", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            isShowingFileImporter = true
                        } label: {
                            Label("Send file", systemImage: "doc")
                        }
                    }
                    if let onFreezeFrame {
                        Button {
                            onFreezeFrame()
                            dismiss()
                        } label: {
                            Label("Freeze frame for Hermes", systemImage: "camera.viewfinder")
                        }
                    }
                }

                Section("Trust mode") {
                    // Show only modes at or below the current trust level.
                    // The phone can only downgrade trust (Trusted -> Step ->
                    // Manual); elevation requires the Mac. Closes FINDING-003.
                    ForEach(ComputerUseTrustMode.allCases.filter { $0 <= snapshot.trustMode }, id: \.self) { mode in
                        Button {
                            onTrustMode(mode)
                            dismiss()
                        } label: {
                            HStack {
                                ComputerUseTrustModeBadge(mode: mode)
                                Spacer()
                                if snapshot.trustMode == mode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }

                Section("Session") {
                    LabeledContent("Actions", value: "\(snapshot.actionsExecuted)")
                    LabeledContent("Spend", value: String(format: "$%.2f", snapshot.dailySpentUSD))
                    if let startedAt = snapshot.startedAt {
                        LabeledContent("Started", value: startedAt.formatted(date: .omitted, time: .shortened))
                    }
                    if let reason = snapshot.lastDeniedReason {
                        LabeledContent("Last denial", value: reason.rawValue)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onPanic()
                        dismiss()
                    } label: {
                        Label("Panic halt", systemImage: "exclamationmark.octagon.fill")
                    }
                }
            }
            .navigationTitle("Phone control")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: photoPickerItem) { _, item in
                guard let item, let onSendWorkspaceFile else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("watch-\(UUID().uuidString).jpg")
                    try? data.write(to: url)
                    onSendWorkspaceFile(url)
                    photoPickerItem = nil
                    dismiss()
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                guard let onSendWorkspaceFile,
                      case .success(let urls) = result,
                      let url = urls.first else { return }
                onSendWorkspaceFile(url)
                dismiss()
            }
        }
    }
}
#endif
