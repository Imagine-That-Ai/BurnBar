# First-run memory step — capture evidence

What a first-time member sees on the onboarding step added by
`AgentLens/Views/Onboarding/OnboardingMemoryView.swift`.

| File | What it shows |
|---|---|
| `screenshot-step-in-window.png` | The step at the wizard's real size (520pt wide), so the fold is where the member actually finds it. |
| `screenshot-step-full.png` | The same step with the scroll view unclipped and an OpenBurnBar MCP server resolvable on the machine, so all seven install rows and their live `Install` buttons are visible in one image. |

Both were rendered from the real SwiftUI view inside the app process
(`NSHostingView` + `cacheDisplay`, driven by a throwaway hosted XCTest that is
deliberately not committed), at the exact frame `OnboardingWizardView` gives its
step content, with the wizard's progress bar and footer drawn around it.

The `Install` buttons are disabled in `screenshot-step-in-window.png` because no
MCP server resolved on that run — the card says so in its own words rather than
writing a config entry that points at nothing. That is the honest first-run state
on a Mac with no checkout in a conventional location.
