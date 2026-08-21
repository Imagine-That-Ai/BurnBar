import Foundation

/// The answers a frightened person actually needs, per permission.
///
/// `SystemPermissionKind` already carries *value* copy -- `onboardingCapabilitySummary`
/// ("what you get"), `onboardingDenialExamples` ("what you lose"), `heroExplanation`.
/// That copy is aimed at somebody who is already sold. It is necessary and it is not
/// sufficient: a user who has just installed the app and is being asked to let it
/// "record this computer's screen" is not weighing features, they are asking whether
/// this is a virus.
///
/// This type answers that question instead, in five fixed slots. Keeping the slots
/// fixed matters: it stops each new permission from inventing its own reassurance and
/// guarantees every ask discloses the same five things, including the unflattering ones.
///
/// **Every claim here must be true and checkable.** A trust surface that overclaims is
/// worse than no trust surface, because the one user who verifies and finds a gap loses
/// confidence in all of it. `SystemPermissionSafetyFrameHonestyTests` enforces the
/// specific claim that has already been got wrong once (see `whereItGoes` below).
public struct SystemPermissionSafetyFrame: Sendable, Hashable, Codable {
    /// Who is on the other side of this permission.
    public let whoWatches: String
    /// Where the resulting data actually goes -- including off this Mac.
    public let whereItGoes: String
    /// Who initiates and who approves.
    public let whoDrives: String
    /// What still works if the user says no. Makes declining visibly safe.
    public let ifYouDecline: String
    /// How to take it back, and what the app does when they do.
    public let howToRevoke: String

    public init(
        whoWatches: String,
        whereItGoes: String,
        whoDrives: String,
        ifYouDecline: String,
        howToRevoke: String
    ) {
        self.whoWatches = whoWatches
        self.whereItGoes = whereItGoes
        self.whoDrives = whoDrives
        self.ifYouDecline = ifYouDecline
        self.howToRevoke = howToRevoke
    }
}

public extension SystemPermissionKind {
    /// Plain-language answers shown *before* macOS's own dialog, so BurnBar is always
    /// the first voice and macOS is the second.
    var safetyFrame: SystemPermissionSafetyFrame {
        switch self {
        case .screenRecording:
            return SystemPermissionSafetyFrame(
                whoWatches: "The agent you're talking to, running on this Mac. Nobody at BurnBar can see your screen.",
                // NOTE: deliberately does NOT say "stays on this Mac". Screenshot content is
                // returned to the configured model provider like any other tool result, and
                // frames go peer-to-peer to a paired iPhone during Agent Watch. Saying
                // otherwise would be a false claim on a trust surface.
                whereItGoes: "There's no BurnBar server in this path. What the agent reads goes to the model provider you already chose \u{2014} the same one reading your prompts. The image and the action log are written to this Mac.",
                whoDrives: "This permission only lets it look \u{2014} clicking and typing is a separate permission. "
                    + "How much the agent does without asking depends on the session mode you choose: Manual stops for "
                    + "every action, Step lets one approval cover a short burst of similar actions, and Trusted runs "
                    + "actions matching rules you wrote without asking again.",
                ifYouDecline: "Everything else works. The agent just can't read your screen \u{2014} you'd paste or describe things instead.",
                howToRevoke: "System Settings \u{2192} Privacy & Security \u{2192} Screen Recording, any time. OpenBurnBar goes back to asking."
            )

        case .accessibility:
            return SystemPermissionSafetyFrame(
                whoWatches: "The same agent, on this Mac. It reads the labels of buttons and fields so it knows what it's about to click.",
                whereItGoes: "The labels, window titles and URLs it reads come back as tool results, so they go to the model provider you already chose \u{2014} the same one reading your prompts. Every action is also appended to a hash-linked log on this Mac that you can open, verify, and export.",
                whoDrives: "You choose how much it does on its own. Manual stops for every action, Step lets one approval cover a short burst, and Trusted runs actions matching rules you wrote without asking again. Control-Option-Command-. halts it instantly from anywhere, in every mode.",
                ifYouDecline: "Chat and quota tracking are unaffected. The agent just can't click or type for you.",
                howToRevoke: "System Settings \u{2192} Privacy & Security \u{2192} Accessibility. Switch it off mid-run and OpenBurnBar halts the session within five seconds \u{2014} you don't have to quit anything."
            )

        case .remoteDesktop:
            return SystemPermissionSafetyFrame(
                whoWatches: "A device you have already paired with this Mac.",
                whereItGoes: "Frames go peer-to-peer to that device. They are not uploaded to BurnBar.",
                whoDrives: "The paired device. This one is genuinely powerful: it can see and type at your login screen.",
                // Telling people to decline the two scariest permissions is what makes the
                // reassurance on the other six worth believing.
                ifYouDecline: "Most people never need this. If you didn't come here for Remote Unlock, say no \u{2014} everything else works without it.",
                howToRevoke: "System Settings \u{2192} Privacy & Security \u{2192} Remote Desktop."
            )

        case .systemExtension:
            return SystemPermissionSafetyFrame(
                whoWatches: "Nobody watches anything. This installs a driver so a paired device can type at the locked login screen.",
                whereItGoes: "Nothing is captured or sent. It only delivers keystrokes you send from your own paired device.",
                whoDrives: "You, from the paired device. It needs an administrator password because installing a system driver always does.",
                ifYouDecline: "Most people never need this. Everything except unlocking this Mac remotely keeps working.",
                howToRevoke: "Remove it from System Settings \u{2192} General \u{2192} Login Items & Extensions."
            )

        case .camera:
            return SystemPermissionSafetyFrame(
                whoWatches: "Only a call or camera check you started yourself.",
                whereItGoes: "Video goes peer-to-peer to the device you're calling. BurnBar does not record or store it.",
                whoDrives: "You. Nothing turns the camera on by itself, and macOS lights its own green dot whenever it is live.",
                ifYouDecline: "Everything except video calls keeps working.",
                howToRevoke: "System Settings \u{2192} Privacy & Security \u{2192} Camera."
            )

        case .microphone:
            return SystemPermissionSafetyFrame(
                whoWatches: "Only a call or microphone check you started yourself.",
                whereItGoes: "Audio goes peer-to-peer to the device you're calling. BurnBar does not record or store it.",
                whoDrives: "You. If macOS isn't showing its orange dot, nothing is listening.",
                ifYouDecline: "Everything except audio calls keeps working.",
                howToRevoke: "System Settings \u{2192} Privacy & Security \u{2192} Microphone."
            )

        case .fullDiskAccess:
            return SystemPermissionSafetyFrame(
                whoWatches: "Nothing watches on its own \u{2014} but be clear about what you are granting: macOS has "
                    + "no per-folder version of this. Full Disk Access opens all of your protected data (Mail, Messages, "
                    + "Safari, Time Machine and more) to OpenBurnBar at once, not just the folder you came here for.",
                whereItGoes: "Nothing is indexed or uploaded merely for holding the grant. But a file an agent actually reads becomes a tool result, and tool results go to the model provider you already chose. Only ask an agent to open files you are willing to send there.",
                whoDrives: "You, by asking an agent for a specific file. OpenBurnBar confines itself to what you asked for; macOS does not enforce that limit, so the grant is broader than our use of it.",
                ifYouDecline: "That one provider stays blocked and is named honestly in the path audit. Everything else keeps working.",
                howToRevoke: "System Settings \u{2192} Privacy & Security \u{2192} Full Disk Access. OpenBurnBar simply starts failing those reads again."
            )

        case .automation:
            return SystemPermissionSafetyFrame(
                whoWatches: "The agent, and only the one app you allow here.",
                whereItGoes: "What it reads from that app is a tool result: it goes to your model provider and to the local action log.",
                whoDrives: "You approve each app separately, and macOS asks once per app. Saying yes to one is not saying yes to the rest.",
                ifYouDecline: "The agent can't drive that app. Every other app you did allow still works.",
                howToRevoke: "System Settings \u{2192} Privacy & Security \u{2192} Automation, under OpenBurnBar."
            )
        }
    }
}
