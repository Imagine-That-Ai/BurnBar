import Foundation
import OpenBurnBarCore

/// Tool descriptors that are safe to expose to LLM runtimes only after a
/// matching `AgentCapabilityGrant` is active.
public enum AgentDesktopToolDefinitions {
    public struct Tool {
        public let name: String
        public let description: String
        public let requiredCapabilities: [AgentDesktopCapability]
        public let parameters: [String: Any]

        public init(
            name: String,
            description: String,
            requiredCapabilities: [AgentDesktopCapability],
            parameters: [String: Any]
        ) {
            self.name = name
            self.description = description
            self.requiredCapabilities = requiredCapabilities
            self.parameters = parameters
        }
    }

    public static let all: [Tool] = [
        browserGoto,
        browserClick,
        browserFill,
        browserKey,
        browserSelect,
        browserScreenshot,
        browserExtract,
        macInputClick,
        macInputType,
        macInputKey,
        macInputShortcut,
        macInputDragDrop,
        macInputScroll,
        macInputPointerMove,
        macInspectAccessibility,
        workspaceReadFile,
        workspaceListFiles,
        workspaceWriteFile,
        desktopExportFile,
        shellRun,
        shellRunUnrestricted
    ]

    public static func tools(for grant: AgentCapabilityGrant, now: Date = Date()) -> [Tool] {
        guard grant.isActive(now: now) else { return [] }
        return all.filter { grant.supportsAll($0.requiredCapabilities, now: now) }
    }

    public static func openAITools(for grant: AgentCapabilityGrant, now: Date = Date()) -> [[String: Any]] {
        tools(for: grant, now: now).map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                ]
            ]
        }
    }

    public static func tool(named name: String) -> Tool? {
        all.first { $0.name == name }
    }

    public static func computerUseToolKind(named name: String) -> BurnBarToolKind? {
        BurnBarToolKind(rawValue: name)
    }

    private static let emptyObjectSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [],
        "properties": [:]
    ]

    private static let browserTargetProperties: [String: Any] = [
        "selector": ["type": "string", "description": "CSS selector when available."],
        "text": ["type": "string", "description": "Text to type."],
        "url": ["type": "string", "description": "URL to navigate to."],
        "key": ["type": "string", "description": "Keyboard key name."],
        "value": ["type": "string", "description": "Value to select."],
        "positionX": ["type": "integer", "description": "Fallback page x coordinate."],
        "positionY": ["type": "integer", "description": "Fallback page y coordinate."],
        "timeoutMillis": ["type": "integer", "description": "Optional action timeout in milliseconds."]
    ]

    private static func browserSchema(required: [String]) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": required,
            "properties": browserTargetProperties
        ]
    }

    private static let macInputProperties: [String: Any] = [
        "displayX": ["type": "integer", "description": "Main-display x coordinate."],
        "displayY": ["type": "integer", "description": "Main-display y coordinate."],
        "dragEndX": ["type": "integer", "description": "Drag destination x coordinate."],
        "dragEndY": ["type": "integer", "description": "Drag destination y coordinate."],
        "deltaX": ["type": "integer", "description": "Horizontal scroll delta."],
        "deltaY": ["type": "integer", "description": "Vertical scroll delta."],
        "mouseButton": ["type": "integer", "description": "Mouse button index, 0 for primary."],
        "text": ["type": "string", "description": "Text to type."],
        "key": ["type": "string", "description": "Keyboard key name."],
        "modifiers": [
            "type": "array",
            "items": ["type": "string"],
            "description": "Shortcut modifiers such as command, option, control, shift."
        ]
    ]

    private static func macInputSchema(required: [String]) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": required,
            "properties": macInputProperties
        ]
    }

    public static let browserGoto = Tool(
        name: BurnBarToolKind.browserGoto.rawValue,
        description: "Navigate the managed desktop browser to a URL.",
        requiredCapabilities: [.desktopBrowser],
        parameters: browserSchema(required: ["url"])
    )

    public static let browserClick = Tool(
        name: BurnBarToolKind.browserClick.rawValue,
        description: "Click a selector or fallback page coordinate in the managed desktop browser.",
        requiredCapabilities: [.desktopBrowser],
        parameters: browserSchema(required: [])
    )

    public static let browserFill = Tool(
        name: BurnBarToolKind.browserFill.rawValue,
        description: "Type text into a field in the managed desktop browser.",
        requiredCapabilities: [.desktopBrowser],
        parameters: browserSchema(required: ["selector", "text"])
    )

    public static let browserKey = Tool(
        name: BurnBarToolKind.browserKey.rawValue,
        description: "Press a key in the managed desktop browser.",
        requiredCapabilities: [.desktopBrowser],
        parameters: browserSchema(required: ["key"])
    )

    public static let browserSelect = Tool(
        name: BurnBarToolKind.browserSelect.rawValue,
        description: "Select a value in a browser dropdown.",
        requiredCapabilities: [.desktopBrowser],
        parameters: browserSchema(required: ["selector", "value"])
    )

    public static let browserScreenshot = Tool(
        name: BurnBarToolKind.browserScreenshot.rawValue,
        description: "Capture the current managed desktop browser page.",
        requiredCapabilities: [.desktopBrowser, .desktopScreenshot],
        parameters: emptyObjectSchema
    )

    public static let browserExtract = Tool(
        name: BurnBarToolKind.browserExtract.rawValue,
        description: "Extract text/content from the current browser page.",
        requiredCapabilities: [.desktopBrowser],
        parameters: browserSchema(required: [])
    )

    public static let macInputClick = Tool(
        name: BurnBarToolKind.macInputClick.rawValue,
        description: "Click a coordinate on this Mac after OpenBurnBar approval/scope checks.",
        requiredCapabilities: [.desktopSystemInput],
        parameters: macInputSchema(required: ["displayX", "displayY"])
    )

    public static let macInputType = Tool(
        name: BurnBarToolKind.macInputType.rawValue,
        description: "Type text into the frontmost Mac app after approval/scope checks.",
        requiredCapabilities: [.desktopSystemInput],
        parameters: macInputSchema(required: ["text"])
    )

    public static let macInputKey = Tool(
        name: BurnBarToolKind.macInputKey.rawValue,
        description: "Press one key in the frontmost Mac app after approval/scope checks.",
        requiredCapabilities: [.desktopSystemInput],
        parameters: macInputSchema(required: ["key"])
    )

    public static let macInputShortcut = Tool(
        name: BurnBarToolKind.macInputShortcut.rawValue,
        description: "Send a keyboard shortcut in the frontmost Mac app after approval/scope checks.",
        requiredCapabilities: [.desktopSystemInput],
        parameters: macInputSchema(required: ["key", "modifiers"])
    )

    public static let macInputDragDrop = Tool(
        name: BurnBarToolKind.macInputDragDrop.rawValue,
        description: "Drag from one coordinate to another after approval/scope checks.",
        requiredCapabilities: [.desktopSystemInput],
        parameters: macInputSchema(required: ["displayX", "displayY", "dragEndX", "dragEndY"])
    )

    public static let macInputScroll = Tool(
        name: BurnBarToolKind.macInputScroll.rawValue,
        description: "Scroll at a coordinate or in the frontmost app after approval/scope checks.",
        requiredCapabilities: [.desktopSystemInput],
        parameters: macInputSchema(required: [])
    )

    public static let macInputPointerMove = Tool(
        name: BurnBarToolKind.macInputPointerMove.rawValue,
        description: "Move the pointer on this Mac after approval/scope checks.",
        requiredCapabilities: [.desktopSystemInput],
        parameters: macInputSchema(required: ["displayX", "displayY"])
    )

    public static let macInspectAccessibility = Tool(
        name: BurnBarToolKind.macInspectAccessibility.rawValue,
        description: "Read the frontmost accessibility tree, or the element at a coordinate.",
        requiredCapabilities: [.accessibilityInspect],
        parameters: macInputSchema(required: [])
    )

    public static let workspaceReadFile = Tool(
        name: "workspace_read_file",
        description: "Read a UTF-8 text file inside the OpenBurnBar chat workspace.",
        requiredCapabilities: [.workspaceRead],
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["path"],
            "properties": [
                "path": ["type": "string", "description": "Workspace-relative path."]
            ]
        ]
    )

    public static let workspaceListFiles = Tool(
        name: "workspace_list_files",
        description: "List files under a workspace-relative directory.",
        requiredCapabilities: [.workspaceRead],
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": [],
            "properties": [
                "path": ["type": "string", "description": "Workspace-relative directory, default root."],
                "limit": ["type": "integer", "description": "Maximum rows to return, default 200."]
            ]
        ]
    )

    public static let workspaceWriteFile = Tool(
        name: "workspace_write_file",
        description: "Write a UTF-8 text file inside the OpenBurnBar chat workspace.",
        requiredCapabilities: [.workspaceWrite],
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["path", "content"],
            "properties": [
                "path": ["type": "string", "description": "Workspace-relative path."],
                "content": ["type": "string", "description": "File content to write."],
                "append": ["type": "boolean", "description": "Append instead of replace."]
            ]
        ]
    )

    public static let desktopExportFile = Tool(
        name: "desktop_export_file",
        description: "Copy a file from the OpenBurnBar chat workspace into the user's Desktop/OpenBurnBar Agent Drops folder.",
        requiredCapabilities: [.workspaceRead, .desktopFileExport],
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["sourcePath"],
            "properties": [
                "sourcePath": ["type": "string", "description": "Workspace-relative file to export."],
                "targetName": ["type": "string", "description": "Optional filename for the Desktop copy."]
            ]
        ]
    )

    public static let shellRun = Tool(
        name: "shell_run",
        description: "Run a shell command in the OpenBurnBar chat workspace with bounded output. Writes outside the workspace are denied by the local sandbox.",
        requiredCapabilities: [.shell],
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["command"],
            "properties": [
                "command": ["type": "string", "description": "Command line to run from the workspace root."],
                "timeoutSeconds": ["type": "integer", "description": "Optional timeout, capped at 60 seconds."]
            ]
        ]
    )

    public static let shellRunUnrestricted = Tool(
        name: "shell_run_unrestricted",
        description: "YOLO only: run a shell command without the workspace write sandbox. Output and timeout are still bounded.",
        requiredCapabilities: [.shellUnrestricted],
        parameters: [
            "type": "object",
            "additionalProperties": false,
            "required": ["command"],
            "properties": [
                "command": ["type": "string", "description": "Command line to run from the workspace root."],
                "timeoutSeconds": ["type": "integer", "description": "Optional timeout, capped at 120 seconds."]
            ]
        ]
    )
}
