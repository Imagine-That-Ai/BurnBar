package com.openburnbar.ui.hermes

import android.content.Context
import androidx.compose.animation.*
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.*
import com.openburnbar.ui.components.*
import com.openburnbar.ui.computeruse.AgentPermissionGrantSheet
import com.openburnbar.ui.navigation.HermesPendingPrompt
import com.openburnbar.ui.text.expandStaticTextSnippetDraft
import com.openburnbar.ui.text.rememberTextExpansionSnippets
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting
import kotlinx.coroutines.launch
import org.json.JSONObject

@Composable
fun HermesView(
    hermesService: HermesService = remember { HermesService() },
    initialThreadId: String? = null
) {
    val context = LocalContext.current
    val textExpansionSnippets by rememberTextExpansionSnippets()
    var showConversationList by remember { mutableStateOf(true) }
    var showSessionsLibrary by remember { mutableStateOf(false) }
    var showSetupWizard by remember { mutableStateOf(false) }
    var showHermesSettings by remember { mutableStateOf(false) }
    var permissionThreadID by remember { mutableStateOf<String?>(null) }
    var conversationTitle by remember { mutableStateOf("New Chat") }
    var tilePrefs by remember { mutableStateOf(loadChatTilePreferences(context).sanitized()) }
    var stagedAttachments by remember { mutableStateOf<List<HermesAttachment>>(emptyList()) }
    val messages by hermesService.messages.collectAsState()
    val isConnected by hermesService.isConnected.collectAsState()
    val isStreaming by hermesService.isStreaming.collectAsState()
    val availableModels by hermesService.availableModels.collectAsState()
    val runtimeInfo by hermesService.runtimeInfo.collectAsState()
    val onboarding = remember(context) { HermesOnboardingState(context.applicationContext) }

    val historyStore = remember(context) {
        com.openburnbar.data.assistants.AssistantChatHistoryStore.shared(context.applicationContext)
    }

    LaunchedEffect(Unit) {
        hermesService.bindHistoryStore(historyStore)
        historyStore.bootstrap()
        hermesService.setChatTilePreferences(tilePrefs)
        hermesService.connect()
        if (onboarding.shouldAutoPresentSetupWizard()) {
            showSetupWizard = true
        }
    }

    LaunchedEffect(initialThreadId) {
        if (!initialThreadId.isNullOrBlank()) {
            val cleanThreadId = initialThreadId.removePrefix("hermes:")
            hermesService.bindHistoryStore(historyStore)
            historyStore.bootstrap()
            hermesService.loadThread(cleanThreadId)
            showConversationList = false
            val thread = historyStore.thread(cleanThreadId)
            if (thread != null) {
                conversationTitle = thread.title
            }
        }
    }

    LaunchedEffect(tilePrefs) {
        hermesService.setChatTilePreferences(tilePrefs)
    }

    // Consume pending prompt from cross-tab navigation
    LaunchedEffect(showConversationList) {
        if (!showConversationList) {
            val pending = HermesPendingPrompt.pending
            if (!pending.isNullOrBlank()) {
                kotlinx.coroutines.delay(300)
                hermesService.sendMessage(pending.trim())
                HermesPendingPrompt.pending = null
            }
        }
    }

    when {
        showSetupWizard -> HermesSetupWizard(
            onComplete = { showSetupWizard = false },
            onOpenConnections = {
                showSetupWizard = false
                showHermesSettings = true
            },
            onDismiss = { showSetupWizard = false }
        )
        showHermesSettings -> HermesSettingsView(
            service = hermesService,
            onDismiss = { showHermesSettings = false }
        )
        showSessionsLibrary -> HermesSessionsScreen(
            service = hermesService,
            onBack = { showSessionsLibrary = false },
            onImported = { imported ->
                hermesService.loadThread(imported)
                showSessionsLibrary = false
                showConversationList = false
                conversationTitle = "Imported session"
            }
        )
        showConversationList -> ConversationListView(
            isConnected = isConnected,
            onStartChat = { title ->
                conversationTitle = title
                showConversationList = false
                hermesService.clearMessages()
                stagedAttachments = emptyList()
            },
            onOpenLibrary = { showSessionsLibrary = true },
            onOpenSetup = { showHermesSettings = true },
            hermesService = hermesService
        )
        else -> {
            val currentThreadID by hermesService.currentThreadID.collectAsState()
            ChatView(
                messages = messages,
                isConnected = isConnected,
                isStreaming = isStreaming,
                availableModels = availableModels,
                runtimeInfo = runtimeInfo,
                conversationTitle = conversationTitle,
                tilePreferences = tilePrefs,
                attachments = stagedAttachments,
                onAddAttachment = { stagedAttachments = (stagedAttachments + it).take(HermesAttachmentLimits.MAX_ATTACHMENTS) },
                onRemoveAttachment = { id -> stagedAttachments = stagedAttachments.filterNot { it.id == id } },
                onTilePreferencesChange = { next ->
                    tilePrefs = next.sanitized()
                    saveChatTilePreferences(context, tilePrefs)
                },
                onBack = { showConversationList = true },
                onSend = { msg, model ->
                    hermesService.sendMessage(msg, model, stagedAttachments)
                    stagedAttachments = emptyList()
                },
                onAgentPermissions = {
                    permissionThreadID = hermesService.ensureDesktopGrantThreadID()
                },
                onDisconnect = { hermesService.disconnect() },
                threadId = currentThreadID.orEmpty(),
                textExpansionSnippets = textExpansionSnippets,
            )
        }
    }

    permissionThreadID?.let { threadID ->
        AgentPermissionGrantSheet(
            runtime = AssistantRuntimeID.HERMES.token,
            threadId = threadID,
            onDismiss = { permissionThreadID = null },
        )
    }
}

// ── ConversationListView ──
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun ConversationListView(
    isConnected: Boolean,
    onStartChat: (String) -> Unit,
    onOpenLibrary: () -> Unit = {},
    onOpenSetup: () -> Unit = {},
    hermesService: HermesService
) {
    val isDark = isSystemInDarkTheme()

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Hermes") },
                actions = {
                    IconButton(onClick = onOpenLibrary) {
                        Icon(Icons.Filled.History, contentDescription = "Library")
                    }
                    IconButton(onClick = onOpenSetup) {
                        Icon(Icons.Filled.Settings, contentDescription = "Setup")
                    }
                },
                colors = TopAppBarDefaults.centerAlignedTopAppBarColors(containerColor = Color.Transparent)
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { onStartChat("New Chat") },
                containerColor = AuroraColors.hermesMercury
            ) {
                Icon(Icons.Filled.Add, contentDescription = "New Chat", tint = Color.White)
            }
        },
        containerColor = Color.Transparent
    ) { innerPadding ->
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            Column(
                modifier = Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                AuroraGlassCard(modifier = Modifier.padding(AuroraSpacing.xl.dp)) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))

                        Box(
                            modifier = Modifier
                                .size(80.dp)
                                .clip(CircleShape)
                                .background(Brush.linearGradient(AuroraGradients.mercuryFoil)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                Icons.Filled.Forum, contentDescription = null,
                                modifier = Modifier.size(40.dp), tint = Color.White
                            )
                        }

                        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

                        Text(
                            text = "Start your first conversation",
                            fontSize = AuroraTypography.title.sp,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface
                        )

                        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))

                        Text(
                            text = "Hermes connects to your Mac to answer questions about your AI burn data.",
                            fontSize = AuroraTypography.body.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = AuroraSpacing.lg.dp)
                        )

                        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

                        Button(
                            onClick = { onStartChat("New Chat") },
                            colors = ButtonDefaults.buttonColors(containerColor = AuroraColors.hermesMercury)
                        ) {
                            Text("Start Chat")
                        }
                    }
                }
            }
        }
    }
}

// ── ChatView ──
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatView(
    messages: List<HermesMessage>,
    isConnected: Boolean,
    availableModels: List<String>,
    runtimeInfo: Map<String, String>,
    conversationTitle: String,
    tilePreferences: ChatTilePreferences,
    onTilePreferencesChange: (ChatTilePreferences) -> Unit,
    onBack: () -> Unit,
    onSend: (String, String) -> Unit,
    onAgentPermissions: () -> Unit,
    onDisconnect: () -> Unit,
    attachments: List<HermesAttachment> = emptyList(),
    onAddAttachment: (HermesAttachment) -> Unit = {},
    onRemoveAttachment: (String) -> Unit = {},
    isStreaming: Boolean = false,
    threadId: String = "",
    textExpansionSnippets: List<com.openburnbar.data.text.TextExpansionSnippet> = emptyList(),
) {
    androidx.compose.runtime.LaunchedEffect(threadId) {
        if (threadId.isNotEmpty()) {
            com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.activeThreadId = threadId
        }
    }
    androidx.compose.runtime.DisposableEffect(threadId) {
        onDispose {
            if (com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.activeThreadId == threadId) {
                com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.activeThreadId = null
            }
        }
    }
    var inputText by remember { mutableStateOf("") }
    var selectedModel by remember(tilePreferences.selectedHermesModelOverride) {
        mutableStateOf(tilePreferences.selectedHermesModelOverride ?: availableModels.firstOrNull() ?: "hermes")
    }
    var showModelPicker by remember { mutableStateOf(false) }
    var showConnectionSettings by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var chatViewMode by remember(context) {
        mutableStateOf(
            ChatViewMode.fromKey(
                context.getSharedPreferences("chat", 0).getString("viewMode", null)
            )
        )
    }
    val listState = rememberLazyListState()
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    val visibleModels = remember(availableModels, tilePreferences.enabledHermesSubProviders, selectedModel) {
        val filtered = if (tilePreferences.enabledHermesSubProviders.isEmpty()) {
            availableModels
        } else {
            availableModels.filter { model ->
                val family = hermesFamilyForModel(model)
                family == null || tilePreferences.enabledHermesSubProviders.contains(family)
            }
        }
        if (selectedModel.isNotBlank() && !filtered.contains(selectedModel)) {
            listOf(selectedModel) + filtered
        } else {
            filtered
        }
    }

    val sendMessage = {
        if (inputText.isNotBlank()) {
            onSend(inputText.trim(), selectedModel)
            inputText = ""
            scope.launch { listState.animateScrollToItem(messages.size + 2) }
            focusManager.clearFocus()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = conversationTitle,
                            fontSize = AuroraTypography.headline.sp,
                            fontWeight = FontWeight.Bold
                        )
                        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                        if (isConnected) BreathingDot(color = AuroraColors.success, size = 8)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = { onDisconnect(); onBack() }) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back"
                        )
                    }
                },
                actions = {
                    IconButton(onClick = { showModelPicker = true }) {
                        Icon(Icons.Filled.Psychology, contentDescription = "Model")
                    }
                    IconButton(onClick = { showConnectionSettings = true }) {
                        Icon(Icons.Filled.Settings, contentDescription = "Settings")
                    }
                    IconButton(onClick = onAgentPermissions) {
                        Icon(Icons.Filled.Security, contentDescription = "Agent permissions")
                    }
                    // View mode toggle: Agent ↔ CLI
                    val viewModeLabel = if (chatViewMode == ChatViewMode.CLI) "Agent view" else "CLI view"
                    val viewModeIcon = if (chatViewMode == ChatViewMode.CLI) Icons.Filled.ChatBubble else Icons.Filled.Terminal
                    IconButton(onClick = {
                        chatViewMode = if (chatViewMode == ChatViewMode.AGENT) ChatViewMode.CLI else ChatViewMode.AGENT
                        context.getSharedPreferences("chat", 0).edit().putString("viewMode", chatViewMode.key).apply()
                    }) {
                        Icon(imageVector = viewModeIcon, contentDescription = viewModeLabel)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        },
        containerColor = Color.Transparent
    ) { innerPadding ->
        Column(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            LazyColumn(
                modifier = Modifier.weight(1f),
                state = listState,
                contentPadding = PaddingValues(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
                verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)
            ) {
                item {
                    WelcomeBlock(
                        runtimeInfo = runtimeInfo,
                        selectedModel = selectedModel,
                        availableModels = visibleModels,
                        onModelSelect = {
                            selectedModel = it
                            onTilePreferencesChange(tilePreferences.setSelectedHermesModel(it))
                        },
                        onTriggerPrompt = { prompt -> onSend(prompt, selectedModel) }
                    )
                }

                items(messages) { message -> ChatBubble(message = message, threadId = threadId, viewMode = chatViewMode) }
            }

            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.55f),
                shape = RoundedCornerShape(28.dp),
                border = BorderStroke(1.dp, Brush.linearGradient(AuroraGradients.glassStroke)),
                tonalElevation = 8.dp
            ) {
                Column(modifier = Modifier.fillMaxWidth()) {
                    HermesAttachmentTray(
                        attachments = attachments,
                        onAddAttachment = onAddAttachment,
                        onRemoveAttachment = onRemoveAttachment,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 4.dp)
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = 14.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        androidx.compose.foundation.text.BasicTextField(
                            value = inputText,
                            onValueChange = { inputText = expandStaticTextSnippetDraft(it, textExpansionSnippets) },
                            enabled = !isStreaming,
                            textStyle = LocalTextStyle.current.copy(
                                color = MaterialTheme.colorScheme.onSurface,
                                fontSize = 15.sp
                            ),
                            cursorBrush = SolidColor(AuroraColors.hermesMercury),
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                            keyboardActions = KeyboardActions(onSend = { sendMessage() }),
                            modifier = Modifier
                                .weight(1f)
                                .padding(vertical = 12.dp),
                            decorationBox = { innerTextField ->
                                Box(modifier = Modifier.fillMaxWidth()) {
                                    if (inputText.isEmpty()) {
                                        Text(
                                            text = "Ask Hermes...",
                                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                            fontSize = 15.sp
                                        )
                                    }
                                    innerTextField()
                                }
                            }
                        )

                        Spacer(modifier = Modifier.width(8.dp))

                        val canSend = inputText.isNotBlank() && !isStreaming
                        val sendBg = when {
                            canSend -> AuroraColors.hermesMercury
                            isStreaming -> AuroraColors.hermesMercury.copy(alpha = 0.35f)
                            else -> Color.Transparent
                        }
                        val sendTint = when {
                            canSend -> Color.White
                            isStreaming -> Color.White.copy(alpha = 0.7f)
                            else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
                        }
                        val outline = if (!canSend && !isStreaming)
                            MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)
                        else
                            Color.Transparent
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .background(
                                    if (canSend)
                                        Brush.radialGradient(listOf(AuroraColors.hermesMercury.copy(alpha = 0.32f), Color.Transparent))
                                    else
                                        SolidColor(Color.Transparent)
                                ),
                            contentAlignment = Alignment.Center
                        ) {
                            IconButton(
                                onClick = sendMessage,
                                enabled = canSend,
                                modifier = Modifier
                                    .size(36.dp)
                                    .clip(CircleShape)
                                    .background(sendBg)
                                    .border(1.dp, outline, CircleShape)
                            ) {
                                Icon(
                                    imageVector = if (isStreaming) Icons.Filled.HourglassEmpty else Icons.AutoMirrored.Filled.Send,
                                    contentDescription = when {
                                        canSend -> "Send message"
                                        isStreaming -> "Waiting for response — send disabled"
                                        else -> "Type a message to enable send"
                                    },
                                    tint = sendTint
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // Model picker
    if (showModelPicker) {
        AlertDialog(
            onDismissRequest = { showModelPicker = false },
            title = { Text("Select Model") },
            text = {
                Column {
                    visibleModels.forEach { model ->
                        Surface(
                            onClick = {
                                selectedModel = model
                                onTilePreferencesChange(tilePreferences.setSelectedHermesModel(model))
                                showModelPicker = false
                            },
                            modifier = Modifier.fillMaxWidth(),
                            color = if (model == selectedModel) AuroraColors.hermesMercury.copy(alpha = 0.15f) else Color.Transparent,
                            shape = RoundedCornerShape(AuroraRadius.sm.dp)
                        ) {
                            Row(modifier = Modifier.padding(AuroraSpacing.sm.dp), verticalAlignment = Alignment.CenterVertically) {
                                com.openburnbar.ui.components.ModelLogo(modelKey = model, size = 24.dp)
                                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                                Text(model, fontSize = AuroraTypography.body.sp, modifier = Modifier.weight(1f))
                                if (model == selectedModel) {
                                    Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(16.dp), tint = AuroraColors.hermesMercury)
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { showModelPicker = false }) { Text("Done") } }
        )
    }

    // Connection settings
    if (showConnectionSettings) {
        AlertDialog(
            onDismissRequest = { showConnectionSettings = false },
            title = { Text("Connection") },
            text = {
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        BreathingDot(color = if (isConnected) AuroraColors.success else AuroraColors.error, size = 8)
                        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                        Text(
                            text = if (isConnected) "Connected" else "Disconnected",
                            fontSize = AuroraTypography.body.sp,
                            color = if (isConnected) AuroraColors.success else AuroraColors.error
                        )
                    }
                    runtimeInfo.forEach { (key, value) ->
                        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text(key, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(value.take(40), fontSize = AuroraTypography.caption.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { showConnectionSettings = false }) { Text("Close") } }
        )
    }
}

// ── Welcome Block ──
@Composable
fun WelcomeBlock(
    runtimeInfo: Map<String, String>,
    selectedModel: String,
    availableModels: List<String>,
    onModelSelect: (String) -> Unit,
    onTriggerPrompt: (String) -> Unit
) {
    val glassStrokeBrush = Brush.linearGradient(AuroraGradients.glassStroke)
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))

        Surface(
            shape = RoundedCornerShape(24.dp),
            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
            border = BorderStroke(1.2.dp, glassStrokeBrush),
            modifier = Modifier.padding(horizontal = 16.dp)
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                    modifier = Modifier
                        .size(80.dp)
                        .background(Brush.linearGradient(AuroraGradients.mercuryGradient), CircleShape)
                        .padding(3.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surface),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.Filled.AutoAwesome,
                            contentDescription = null,
                            modifier = Modifier.size(38.dp),
                            tint = AuroraColors.hermesMercury
                        )
                    }
                }

                Spacer(modifier = Modifier.height(16.dp))

                Text(
                    text = "Hermes is ready",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = AuroraColors.hermesMercury
                )

                if (runtimeInfo.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(12.dp))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        runtimeInfo["host"]?.let { host ->
                            Surface(
                                shape = RoundedCornerShape(percent = 50),
                                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
                                border = BorderStroke(0.75.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.22f)),
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(
                                        imageVector = Icons.Filled.Computer,
                                        contentDescription = null,
                                        modifier = Modifier.size(13.dp),
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                    Spacer(modifier = Modifier.width(6.dp))
                                    Text(
                                        text = host,
                                        fontSize = 11.sp,
                                        fontWeight = FontWeight.Medium,
                                        color = MaterialTheme.colorScheme.onSurface
                                    )
                                }
                            }
                        }
                        Surface(
                            shape = RoundedCornerShape(percent = 50),
                            color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
                            border = BorderStroke(0.75.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.22f)),
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                com.openburnbar.ui.components.ModelLogo(modelKey = selectedModel, size = 13.dp)
                                Spacer(modifier = Modifier.width(6.dp))
                                Text(
                                    text = selectedModel,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                            }
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(28.dp))

        val prompts = listOf(
            "What's my burn today?",
            "Show top providers",
            "Forecast my spend",
            "Analyze recent sessions"
        )
        Text(
            text = "SUGGESTED PROMPTS",
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            letterSpacing = 1.sp,
            modifier = Modifier.padding(bottom = 8.dp)
        )
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(horizontal = 16.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            items(prompts) { prompt ->
                Surface(
                    shape = RoundedCornerShape(percent = 50),
                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.25f),
                    border = BorderStroke(0.75.dp, AuroraColors.hermesMercury.copy(alpha = 0.35f)),
                    modifier = Modifier.padding(vertical = 4.dp),
                ) {
                    Text(
                        text = prompt,
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier
                            .clip(RoundedCornerShape(percent = 50))
                            .clickable { onTriggerPrompt(prompt) }
                            .padding(horizontal = 14.dp, vertical = 9.dp)
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(20.dp))
        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.12f))
    }
}

// ── Chat Bubble ──
@Composable
fun ChatBubble(
    message: HermesMessage,
    viewMode: ChatViewMode = ChatViewMode.AGENT,
    threadId: String = "",
) {
    val isUser = message.role == "user"
    val context = androidx.compose.ui.platform.LocalContext.current
    val permissionItems by com.openburnbar.data.computeruse.SystemPermissionInboxStoreHolder.store.items
        .collectAsState()
    val matchingPermissionItem = remember(permissionItems, message.id, threadId) {
        val threadItems = permissionItems[threadId]?.values ?: emptyList()
        threadItems.firstOrNull { item ->
            item.originatingToolCallId == message.id ||
                message.toolCalls.any { tc -> tc.id == item.originatingToolCallId }
        }
    }
    var presentedPermissionItem by remember {
        mutableStateOf<com.openburnbar.data.computeruse.SystemPermissionItem?>(null)
    }
    if (viewMode == ChatViewMode.CLI) {
        HermesCLIMessageRow(message = message, isUser = isUser)
    } else {
        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = if (isUser) Alignment.End else Alignment.Start
        ) {
            if (!isUser) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(start = AuroraSpacing.md.dp + 4.dp, bottom = AuroraSpacing.xxs.dp)
                ) {
                    BreathingDot(
                        color = if (message.isStreaming) AuroraColors.success else AuroraColors.hermesMercury,
                        size = 6
                    )
                    Spacer(modifier = Modifier.width(AuroraSpacing.xs.dp))
                    Text(
                        text = "via Hermes · ${message.modelName}",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.75f)
                    )
                }
            }

            Surface(
                shape = RoundedCornerShape(
                    topStart = 18.dp, topEnd = 18.dp,
                    bottomStart = if (isUser) 18.dp else 4.dp,
                    bottomEnd = if (isUser) 4.dp else 18.dp
                ),
                color = if (isUser)
                    AuroraColors.hermesMercury.copy(alpha = 0.12f)
                else
                    MaterialTheme.colorScheme.surface.copy(alpha = 0.35f),
                border = BorderStroke(
                    width = 0.75.dp,
                    brush = Brush.linearGradient(
                        if (isUser)
                            listOf(AuroraColors.hermesMercury.copy(alpha = 0.45f), AuroraColors.hermesAureate.copy(alpha = 0.15f))
                        else
                            listOf(AuroraColors.hermesMercury.copy(alpha = 0.28f), MaterialTheme.colorScheme.outline.copy(alpha = 0.12f))
                    )
                ),
                modifier = Modifier.widthIn(max = 320.dp)
            ) {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                    Text(
                        text = if (message.content.isEmpty() && message.isStreaming) "…" else message.content,
                        fontSize = 15.sp,
                        color = if (message.isError) AuroraColors.error else MaterialTheme.colorScheme.onSurface,
                        lineHeight = 20.sp
                    )

                    if (message.toolCalls.isNotEmpty()) {
                        Spacer(modifier = Modifier.height(8.dp))
                        LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            items(message.toolCalls) { tc ->
                                val visualKind = toolCallVisualKind(tc.name)
                                val isDone = tc.result?.trim()?.isNotEmpty() == true
                                val statusColor = if (isDone) Color(0xFF22C55E) else Color(0xFFF59E0B)
                                Surface(
                                    shape = RoundedCornerShape(12.dp),
                                    color = MaterialTheme.colorScheme.surface.copy(alpha = 0.45f),
                                    border = BorderStroke(
                                        width = 0.8.dp,
                                        brush = Brush.linearGradient(listOf(AuroraColors.hermesMercury.copy(alpha = 0.45f), statusColor.copy(alpha = 0.25f)))
                                    ),
                                    modifier = Modifier.widthIn(max = 240.dp)
                                ) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp)
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .size(24.dp)
                                                .clip(CircleShape)
                                                .background(AuroraColors.hermesMercury.copy(alpha = 0.12f))
                                                .border(0.5.dp, AuroraColors.hermesMercury.copy(alpha = 0.35f), CircleShape),
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Icon(
                                                imageVector = toolCallIcon(visualKind),
                                                contentDescription = null,
                                                tint = AuroraColors.hermesMercury,
                                                modifier = Modifier.size(12.dp)
                                            )
                                        }
                                        Column {
                                            Text(
                                                text = tc.name,
                                                fontSize = 11.sp,
                                                fontWeight = FontWeight.Bold,
                                                fontFamily = FontFamily.Monospace,
                                                color = MaterialTheme.colorScheme.onSurface,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(4.dp)
                                            ) {
                                                Box(
                                                    modifier = Modifier
                                                        .size(6.dp)
                                                        .background(statusColor, CircleShape)
                                                )
                                                Text(
                                                    text = if (isDone) "completed" else "running",
                                                    fontSize = 9.sp,
                                                    fontWeight = FontWeight.Medium,
                                                    color = statusColor,
                                                    maxLines = 1,
                                                    overflow = TextOverflow.Ellipsis
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (message.tokensPerSecond != null) {
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = "${"%.1f".format(message.tokensPerSecond)} t/s",
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                        )
                    }

                    matchingPermissionItem?.let { item ->
                        Spacer(modifier = Modifier.height(8.dp))
                        com.openburnbar.ui.computeruse.SystemPermissionInlinePill(
                            item = item,
                            onTap = { presentedPermissionItem = item },
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(if (isUser) AuroraSpacing.xxs.dp else AuroraSpacing.sm.dp))
        }
    }

    presentedPermissionItem?.let { item ->
        com.openburnbar.ui.computeruse.SystemPermissionGrantBottomSheet(
            item = item,
            onDismiss = { presentedPermissionItem = null },
            sendPermissionRequest = { request ->
                try {
                    val controller = com.openburnbar.BurnBarApplication.agentCapabilityGrantController
                        ?: com.openburnbar.data.computeruse.AgentCapabilityGrantController(
                            context.applicationContext,
                        ).also {
                            com.openburnbar.BurnBarApplication.agentCapabilityGrantController = it
                        }
                    controller.sendSystemPermissionRequest(request)
                    Result.success(Unit)
                } catch (t: Throwable) {
                    Result.failure(t)
                }
            },
        )
    }
}

/// Builds a short human-readable preview for a Hermes tool call: prefer the
/// result snippet when the daemon has already run the tool, else extract one
/// of the well-known argument keys (path / command / query / etc.) from the
/// (possibly partial) JSON arguments string. Returns `null` when there's
/// nothing useful to show — the bubble keeps the name-only pill in that case.
// MARK: - CLI message row for Hermes chat

@Composable
private fun HermesCLIMessageRow(message: HermesMessage, isUser: Boolean) {
    val toolLines = message.toolCalls.map { tc ->
        val detail = summarizeHermesToolDetail(tc)?.takeIf { it.isNotBlank() }
        "⟨${tc.name}${if (detail != null) ": $detail" else ""}⟩"
    }
    val fullText = if (toolLines.isNotEmpty()) {
        (listOf(message.content) + toolLines).filter { it.isNotBlank() }.joinToString("\n")
    } else {
        message.content
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.35f), RoundedCornerShape(8.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = if (isUser) ">" else "☿",
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = FontFamily.Monospace,
            color = if (isUser) Color(0xFF22C55E) else Color(0xFFD4AA3C),
            modifier = Modifier.width(16.dp),
        )
        Text(
            text = fullText,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            color = Color(0xFFE6EDF3),
            modifier = Modifier.weight(1f),
        )
    }
}

fun summarizeHermesToolDetail(tc: ToolCall): String? {
    val result = tc.result?.trim().orEmpty()
    if (result.isNotEmpty()) {
        return result.take(200)
    }
    val args = tc.arguments.trim()
    if (args.isEmpty()) return null
    runCatching {
        val obj = JSONObject(args)
        for (key in listOf("path", "file_path", "command", "pattern", "query", "url", "prompt")) {
            val value = obj.optString(key)
            if (!value.isNullOrEmpty()) return value.take(200)
        }
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val value = obj.optString(k)
            if (!value.isNullOrEmpty()) return value.take(200)
        }
    }
    for (key in listOf("path", "file_path", "command", "pattern", "query", "url", "prompt")) {
        val pattern = "\"$key\"\\s*:\\s*\"([^\"]+)\"".toRegex()
        val match = pattern.find(args)
        if (match != null && match.groupValues.size >= 2) {
            val value = match.groupValues[1]
            if (value.isNotEmpty()) return value.take(200)
        }
    }
    return null
}

private fun loadChatTilePreferences(context: Context): ChatTilePreferences {
    val prefs = context.getSharedPreferences("chat.tile_preferences", Context.MODE_PRIVATE)
    return ChatTilePreferences.fromJsonString(prefs.getString(ChatTilePreferences.USER_DEFAULTS_KEY, null))
}

private fun saveChatTilePreferences(context: Context, value: ChatTilePreferences) {
    val prefs = context.getSharedPreferences("chat.tile_preferences", Context.MODE_PRIVATE)
    prefs.edit().putString(ChatTilePreferences.USER_DEFAULTS_KEY, value.toJsonString()).apply()
}

private fun hermesFamilyForModel(model: String): HermesSubProvider? {
    val normalized = model.lowercase().replace(" ", "")
    HermesSubProvider.fromToken(normalized)?.let { return it }
    return when {
        "claude" in normalized || "anthropic" in normalized -> HermesSubProvider.CLAUDE
        "codex" in normalized || "openai" in normalized || normalized.startsWith("gpt-") -> HermesSubProvider.CODEX
        "zai" in normalized || "z.ai" in normalized || "glm" in normalized -> HermesSubProvider.ZAI
        "kimi" in normalized || "moonshot" in normalized -> HermesSubProvider.KIMI
        "minimax" in normalized -> HermesSubProvider.MINIMAX
        "ollama" in normalized || "llama" in normalized || "mistral" in normalized || "qwen" in normalized -> HermesSubProvider.OLLAMA
        else -> null
    }
}
