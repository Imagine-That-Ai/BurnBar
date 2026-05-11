package com.openburnbar.ui.hermes

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
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.hermes.*
import com.openburnbar.ui.components.*
import com.openburnbar.ui.navigation.HermesPendingPrompt
import com.openburnbar.ui.theme.*
import com.openburnbar.util.Formatting
import kotlinx.coroutines.launch

@Composable
fun HermesView(
    hermesService: HermesService = remember { HermesService() }
) {
    var showConversationList by remember { mutableStateOf(true) }
    var conversationTitle by remember { mutableStateOf("New Chat") }
    val messages by hermesService.messages.collectAsState()
    val isConnected by hermesService.isConnected.collectAsState()
    val availableModels by hermesService.availableModels.collectAsState()
    val runtimeInfo by hermesService.runtimeInfo.collectAsState()

    LaunchedEffect(Unit) { hermesService.connect() }

    // Consume pending prompt from cross-tab navigation
    LaunchedEffect(showConversationList) {
        if (!showConversationList) {
            val pending = HermesPendingPrompt.pending
            if (!pending.isNullOrBlank()) {
                // Small delay to let the composable settle
                kotlinx.coroutines.delay(300)
                hermesService.sendMessage(pending.trim())
                HermesPendingPrompt.pending = null
            }
        }
    }

    if (showConversationList) {
        ConversationListView(
            isConnected = isConnected,
            onStartChat = { title ->
                conversationTitle = title
                showConversationList = false
                hermesService.clearMessages()
            },
            hermesService = hermesService
        )
    } else {
        ChatView(
            messages = messages,
            isConnected = isConnected,
            availableModels = availableModels,
            runtimeInfo = runtimeInfo,
            conversationTitle = conversationTitle,
            onBack = { showConversationList = true },
            onSend = { msg, model -> hermesService.sendMessage(msg, model) },
            onDisconnect = { hermesService.disconnect() }
        )
    }
}

// ── ConversationListView ──
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun ConversationListView(
    isConnected: Boolean,
    onStartChat: (String) -> Unit,
    hermesService: HermesService
) {
    val isDark = isSystemInDarkTheme()

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Hermes") },
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
        containerColor = if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground
    ) { innerPadding ->
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            AuroraBackdrop(isDark = isDark)

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
    onBack: () -> Unit,
    onSend: (String, String) -> Unit,
    onDisconnect: () -> Unit
) {
    var inputText by remember { mutableStateOf("") }
    var selectedModel by remember { mutableStateOf(availableModels.firstOrNull() ?: "hermes") }
    var showModelPicker by remember { mutableStateOf(false) }
    var showConnectionSettings by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()

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
                        Icon(Icons.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { showModelPicker = true }) {
                        Icon(Icons.Filled.Psychology, contentDescription = "Model")
                    }
                    IconButton(onClick = { showConnectionSettings = true }) {
                        Icon(Icons.Filled.Settings, contentDescription = "Settings")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        },
        containerColor = if (isSystemInDarkTheme()) AuroraColors.darkBackground else AuroraColors.lightBackground
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
                        availableModels = availableModels,
                        onModelSelect = { selectedModel = it },
                        onTriggerPrompt = { prompt -> onSend(prompt, selectedModel) }
                    )
                }

                items(messages) { message -> ChatBubble(message = message) }
            }

            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = (if (isSystemInDarkTheme()) AuroraColors.darkSurface else AuroraColors.lightSurface).copy(alpha = 0.95f),
                tonalElevation = 4.dp
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    OutlinedTextField(
                        value = inputText,
                        onValueChange = { inputText = it },
                        modifier = Modifier.weight(1f),
                        placeholder = { Text("Ask Hermes...", fontSize = AuroraTypography.body.sp) },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                        keyboardActions = KeyboardActions(onSend = { sendMessage() }),
                        shape = RoundedCornerShape(AuroraRadius.lg.dp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = AuroraColors.hermesMercury,
                            unfocusedBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.3f)
                        ),
                        maxLines = 5,
                        textStyle = LocalTextStyle.current.copy(fontSize = AuroraTypography.body.sp)
                    )

                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))

                    IconButton(
                        onClick = sendMessage,
                        enabled = inputText.isNotBlank(),
                        modifier = Modifier.size(40.dp).clip(CircleShape).background(
                            if (inputText.isNotBlank()) AuroraColors.hermesMercury else Color.Transparent
                        )
                    ) {
                        Icon(
                            Icons.Filled.Send, contentDescription = "Send",
                            tint = if (inputText.isNotBlank()) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
                        )
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
                    availableModels.forEach { model ->
                        Surface(
                            onClick = { selectedModel = model; showModelPicker = false },
                            modifier = Modifier.fillMaxWidth(),
                            color = if (model == selectedModel) AuroraColors.hermesMercury.copy(alpha = 0.15f) else Color.Transparent,
                            shape = RoundedCornerShape(AuroraRadius.sm.dp)
                        ) {
                            Row(modifier = Modifier.padding(AuroraSpacing.sm.dp), verticalAlignment = Alignment.CenterVertically) {
                                if (model == selectedModel) {
                                    Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(16.dp), tint = AuroraColors.hermesMercury)
                                    Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                                }
                                Text(model, fontSize = AuroraTypography.body.sp)
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
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.xl.dp))

        Box(
            modifier = Modifier.size(64.dp).clip(CircleShape).background(
                Brush.linearGradient(AuroraGradients.mercuryFoil)
            ),
            contentAlignment = Alignment.Center
        ) {
            Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(32.dp), tint = Color.White)
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        Text(
            text = "Hermes is ready",
            fontSize = AuroraTypography.headline.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface
        )

        if (runtimeInfo.isNotEmpty()) {
            Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
                runtimeInfo["host"]?.let { host ->
                    AssistChip(
                        onClick = {},
                        label = { Text(host, fontSize = AuroraTypography.tiny.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        leadingIcon = { Icon(Icons.Filled.Computer, contentDescription = null, modifier = Modifier.size(14.dp)) }
                    )
                }
                AssistChip(
                    onClick = {},
                    label = { Text(selectedModel, fontSize = AuroraTypography.tiny.sp) },
                    leadingIcon = { Icon(Icons.Filled.Psychology, contentDescription = null, modifier = Modifier.size(14.dp)) }
                )
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

        val prompts = listOf(
            "What's my burn today?",
            "Show top providers",
            "Forecast my spend",
            "Analyze recent sessions"
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
            items(prompts) { prompt ->
                SuggestionChip(
                    onClick = { onTriggerPrompt(prompt) },
                    label = { Text(prompt, fontSize = AuroraTypography.caption.sp) }
                )
            }
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))
        HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = 0.2f))
    }
}

// ── Chat Bubble ──
@Composable
fun ChatBubble(message: HermesMessage) {
    val isUser = message.role == "user"

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
                Spacer(modifier = Modifier.width(AuroraSpacing.xxs.dp))
                Text(
                    text = "via Hermes · ${message.modelName}",
                    fontSize = AuroraTypography.tiny.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        Box(
            modifier = Modifier
                .widthIn(max = 320.dp)
                .clip(RoundedCornerShape(
                    topStart = 18.dp, topEnd = 18.dp,
                    bottomStart = if (isUser) 18.dp else 6.dp,
                    bottomEnd = if (isUser) 6.dp else 18.dp
                ))
                .background(if (isUser) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.surface)
                .then(
                    if (!isUser) Modifier.border(
                        0.5.dp, AuroraColors.hermesMercury.copy(alpha = 0.3f),
                        RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp, bottomStart = 6.dp, bottomEnd = 18.dp)
                    ) else Modifier
                )
                .padding(horizontal = AuroraSpacing.md.dp, vertical = AuroraSpacing.sm.dp)
        ) {
            Column {
                Text(
                    text = message.content,
                    fontSize = AuroraTypography.body.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                    lineHeight = 20.sp
                )

                if (message.toolCalls.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
                    message.toolCalls.forEach { tc ->
                        Surface(
                            modifier = Modifier.padding(vertical = AuroraSpacing.xxs.dp),
                            color = AuroraColors.hermesMercury.copy(alpha = 0.1f),
                            shape = RoundedCornerShape(AuroraRadius.sm.dp)
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = AuroraSpacing.sm.dp, vertical = AuroraSpacing.xxs.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    imageVector = when {
                                        tc.name.contains("search") -> Icons.Filled.Search
                                        tc.name.contains("terminal") || tc.name.contains("bash") -> Icons.Filled.Terminal
                                        tc.name.contains("edit") || tc.name.contains("write") -> Icons.Filled.Edit
                                        else -> Icons.Filled.Code
                                    },
                                    contentDescription = null,
                                    modifier = Modifier.size(14.dp),
                                    tint = AuroraColors.hermesMercury
                                )
                                Spacer(modifier = Modifier.width(AuroraSpacing.xxs.dp))
                                Text(tc.name, fontSize = AuroraTypography.tiny.sp, color = AuroraColors.hermesMercury)
                            }
                        }
                    }
                }

                if (message.tokensPerSecond != null) {
                    Spacer(modifier = Modifier.height(AuroraSpacing.xxs.dp))
                    Text(
                        "${"%.1f".format(message.tokensPerSecond)} t/s",
                        fontSize = AuroraTypography.tiny.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(if (isUser) AuroraSpacing.xxs.dp else AuroraSpacing.sm.dp))
    }
}
