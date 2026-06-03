@file:Suppress("MagicNumber", "LongParameterList")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.auth

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.R
import com.openburnbar.data.stores.AuthError
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.theme.AuroraColors
import kotlin.math.PI
import kotlin.math.sin

// ── Adaptive Login Tokens ──
// Matches iOS `DesignSystemTokens` light/dark values exactly.
// Uses `AuroraColors` (which mirrors the shared `ThemePrimitives.swift` hex values)
// so the login screen adapts to system appearance like iOS does.
internal object LoginAdaptiveTokens {
    @Composable fun ember(): Color = if (isSystemInDarkTheme()) AuroraColors.emberDark else AuroraColors.ember
    @Composable fun amber(): Color = if (isSystemInDarkTheme()) AuroraColors.amberDark else AuroraColors.amber
    @Composable fun blaze(): Color = AuroraColors.blaze
    @Composable fun background(): Color = if (isSystemInDarkTheme()) AuroraColors.darkBackground else AuroraColors.lightBackground
    @Composable fun surface(): Color = if (isSystemInDarkTheme()) AuroraColors.darkSurface else AuroraColors.lightSurface
    @Composable fun surfaceElevated(): Color = if (isSystemInDarkTheme()) AuroraColors.darkSurfaceElevated else AuroraColors.lightSurfaceElevated
    @Composable fun border(): Color = if (isSystemInDarkTheme()) AuroraColors.darkBorder else AuroraColors.lightBorder
    @Composable fun textPrimary(): Color = if (isSystemInDarkTheme()) AuroraColors.darkTextPrimary else AuroraColors.lightTextPrimary
    @Composable fun textSecondary(): Color = if (isSystemInDarkTheme()) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary
    @Composable fun textMuted(): Color = if (isSystemInDarkTheme()) AuroraColors.darkTextMuted else AuroraColors.lightTextMuted
    @Composable fun errorColor(): Color = if (isSystemInDarkTheme()) Color(0xFFFA5053) else Color(0xFFD43030)

    // iOS: primaryGradient = LinearGradient(ember → amber → blaze)
    @Composable fun primaryGradient(): Brush = Brush.horizontalGradient(
        colors = listOf(ember(), amber(), blaze()),
    )
}

internal data class LoginScreenContentState(
    val inFlightProvider: LoginProvider?,
    val emailExpanded: Boolean,
    val emailMode: EmailMode,
    val email: String,
    val password: String,
    val authError: AuthError?,
)

internal data class LoginScreenContentCallbacks(
    val onSetInFlightProvider: (LoginProvider?) -> Unit,
    val onEmailExpandedChange: (Boolean) -> Unit,
    val onEmailModeChange: (EmailMode) -> Unit,
    val onEmailChange: (String) -> Unit,
    val onPasswordChange: (String) -> Unit,
    val onDismissError: () -> Unit,
    val onClearFocus: () -> Unit,
)

@Composable
internal fun LoginScreenGoogleAuthEffects(
    userStore: UserStore,
    isSigningIn: Boolean,
    onInFlightProviderChange: (LoginProvider?) -> Unit,
) {
    val context = LocalContext.current
    LaunchedEffect(isSigningIn) {
        if (!isSigningIn) onInFlightProviderChange(null)
    }
    val googleLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == Activity.RESULT_OK) {
                userStore.handleGoogleSignInResult(result.data)
            } else {
                onInFlightProviderChange(null)
            }
        }
    val needsLegacyFallback by userStore.needsLegacyGoogleFallback.collectAsState()
    LaunchedEffect(needsLegacyFallback) {
        if (needsLegacyFallback) {
            googleLauncher.launch(userStore.getGoogleSignInIntent(context))
            userStore.consumeLegacyGoogleFallback()
        }
    }
}

// ── EmberBackdrop ──
// Matches iOS EmberBackdrop: vertical gradient + two drifting radial-gradient orbs.
@Composable
internal fun EmberBackdrop() {
    val isDark = isSystemInDarkTheme()
    val transition = rememberInfiniteTransition(label = "ember-backdrop")
    val drift by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec =
        infiniteRepeatable(
            animation = tween(durationMillis = 9000, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "drift",
    )
    val bg = LoginAdaptiveTokens.background()
    val srf = LoginAdaptiveTokens.surface()
    val ember = LoginAdaptiveTokens.ember()
    val amber = LoginAdaptiveTokens.amber()

    Box(modifier = Modifier.fillMaxSize()) {
        // Base vertical gradient — matches iOS LinearGradient([background, background, surface])
        Box(
            modifier =
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colors = listOf(bg, bg, srf),
                    ),
                ),
        )
        // Ember orb — upper-left, drifts slowly. Uses radial gradient like iOS.
        EmberOrb(
            color = ember.copy(alpha = if (isDark) 0.55f else 0.35f),
            size = 460.dp,
            blurRadius = 60.dp,
            offsetX = (-80f + drift * -40f).dp,
            offsetY = (-220f + drift * 40f).dp,
        )
        // Amber orb — lower-right, counter-drifts.
        EmberOrb(
            color = amber.copy(alpha = if (isDark) 0.45f else 0.30f),
            size = 420.dp,
            blurRadius = 70.dp,
            offsetX = (100f + drift * 40f).dp,
            offsetY = (260f + drift * -40f).dp,
        )
    }
}

@Composable
private fun EmberOrb(
    color: Color,
    size: androidx.compose.ui.unit.Dp,
    blurRadius: androidx.compose.ui.unit.Dp,
    offsetX: androidx.compose.ui.unit.Dp,
    offsetY: androidx.compose.ui.unit.Dp,
) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .size(size)
                .graphicsLayer {
                    translationX = offsetX.toPx()
                    translationY = offsetY.toPx()
                }
                .blur(blurRadius, edgeTreatment = androidx.compose.ui.draw.BlurredEdgeTreatment.Unbounded)
                .background(
                    Brush.radialGradient(
                        colors = listOf(color, color.copy(alpha = color.alpha * 0.5f), Color.Transparent),
                    ),
                ),
        )
    }
}

internal enum class LoginProvider { Apple, Google, GitHub, Email }

internal enum class EmailMode { SignIn, Create }

internal data class EmailPaneState(
    val mode: EmailMode,
    val email: String,
    val password: String,
    val isSubmitting: Boolean,
    val inFlight: Boolean,
)

internal data class EmailPaneCallbacks(
    val onModeChange: (EmailMode) -> Unit,
    val onEmailChange: (String) -> Unit,
    val onPasswordChange: (String) -> Unit,
    val onClose: () -> Unit,
    val onSubmit: () -> Unit,
)

// ── EmberLogo ──
// Exact port of iOS EmberLogo: multi-frequency flicker, lateral lean,
// vertical stretch anchored at bottom, radial halo, tip glow overlay,
// and rising embers confined to the flame body.
@Composable
internal fun EmberLogo(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "ember-logo")

    // --- Flicker: three incommensurate sine waves (iOS: f1=0.9Hz, f2=2.1Hz, f3=3.7Hz) ---
    val flickerPhase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 100f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 100_000, easing = LinearEasing),
        ),
        label = "flicker-phase",
    )
    val t = flickerPhase.toDouble()
    val f1 = sin(t * 2.0 * PI * 0.9)
    val f2 = sin(t * 2.0 * PI * 2.1 + 1.7)
    val f3 = sin(t * 2.0 * PI * 3.7 + 0.4)
    val flicker = f1 * 0.5 + f2 * 0.3 + f3 * 0.2
    val intensity = (0.5 + 0.5 * flicker).toFloat()

    // --- Lateral lean: two slow incommensurate sines (iOS: 0.45Hz + 0.27Hz) ---
    val leanRaw = sin(t * 2.0 * PI * 0.45 + 0.9) * 0.6 +
        sin(t * 2.0 * PI * 0.27) * 0.4
    val leanDegrees = (leanRaw * 1.4).toFloat()

    // --- Vertical lick: anchored at bottom, flame stretches upward ---
    val stretchY = 1.0f + intensity * 0.07f
    val squeezeX = 1.0f - intensity * 0.025f

    // --- Halo: tracks flicker intensity (iOS halo) ---
    val haloScale = 0.95f + intensity * 0.18f
    val haloOpacity = 0.55f + intensity * 0.40f

    val ember = LoginAdaptiveTokens.ember()
    val amber = LoginAdaptiveTokens.amber()

    Box(
        modifier = modifier.semantics { contentDescription = "OpenBurnBar logo" },
        contentAlignment = Alignment.Center,
    ) {
        // Radial halo — warm glow behind the flame, scales with flicker
        Box(
            modifier = Modifier
                .size(220.dp)
                .scale(haloScale)
                .alpha(haloOpacity)
                .blur(20.dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            ember.copy(alpha = 0.55f),
                            amber.copy(alpha = 0.32f),
                            Color.Transparent,
                        ),
                    ),
                ),
        )

        // Logo image with flame dynamics — lean, stretch, squeeze
        Box(
            modifier = Modifier
                .size(132.dp)
                .graphicsLayer {
                    scaleX = squeezeX
                    scaleY = stretchY
                    rotationZ = leanDegrees
                    transformOrigin = androidx.compose.ui.graphics.TransformOrigin(0.5f, 1.0f)
                    compositingStrategy = CompositingStrategy.Auto
                },
        ) {
            Image(
                painter = painterResource(id = R.drawable.logo_app),
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

// ── EmailPane ──
@Composable
internal fun EmailPane(state: EmailPaneState, modifier: Modifier = Modifier, callbacks: EmailPaneCallbacks) {
    val srf = LoginAdaptiveTokens.surface()
    val border = LoginAdaptiveTokens.border()

    Column(
        modifier =
        modifier
            .clip(RoundedCornerShape(16.dp))
            .background(srf.copy(alpha = 0.85f))
            .border(BorderStroke(1.dp, border), RoundedCornerShape(16.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        EmailPaneHeader(
            mode = state.mode,
            onModeChange = callbacks.onModeChange,
            onClose = callbacks.onClose,
        )
        AuthField(
            value = state.email,
            placeholder = "Email",
            onValueChange = callbacks.onEmailChange,
            keyboardType = KeyboardType.Email,
            imeAction = ImeAction.Next,
        )
        AuthField(
            value = state.password,
            placeholder = "Password",
            onValueChange = callbacks.onPasswordChange,
            keyboardType = KeyboardType.Password,
            imeAction = ImeAction.Done,
            isPassword = true,
            onImeAction = callbacks.onSubmit,
        )
        EmailSubmitButton(
            title = if (state.mode == EmailMode.SignIn) "Sign in" else "Create account",
            isLoading = state.isSubmitting,
            enabled = !state.inFlight && state.email.isNotBlank() && state.password.length >= 6,
            onClick = callbacks.onSubmit,
        )
    }
}

@Composable
private fun EmailPaneHeader(mode: EmailMode, onModeChange: (EmailMode) -> Unit, onClose: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        EmailModePill(title = "Sign in", selected = mode == EmailMode.SignIn, onClick = { onModeChange(EmailMode.SignIn) })
        EmailModePill(title = "Create", selected = mode == EmailMode.Create, onClick = { onModeChange(EmailMode.Create) })
        Spacer(modifier = Modifier.width(1.dp).weight(1f))
        IconButton(onClick = onClose, modifier = Modifier.size(28.dp)) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Close email sign-in",
                tint = LoginAdaptiveTokens.textMuted(),
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun EmailModePill(title: String, selected: Boolean, onClick: () -> Unit) {
    val ember = LoginAdaptiveTokens.ember()
    val bg = if (selected) ember else LoginAdaptiveTokens.surfaceElevated()
    val fg = if (selected) Color.White else LoginAdaptiveTokens.textPrimary()
    Box(
        modifier =
        Modifier
            .clip(RoundedCornerShape(999.dp))
            .background(bg)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(text = title, color = fg, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun AuthField(
    value: String,
    placeholder: String,
    onValueChange: (String) -> Unit,
    keyboardType: KeyboardType,
    imeAction: ImeAction,
    isPassword: Boolean = false,
    onImeAction: () -> Unit = {},
) {
    val ember = LoginAdaptiveTokens.ember()
    val surfEl = LoginAdaptiveTokens.surfaceElevated()
    val border = LoginAdaptiveTokens.border()
    val textPrimary = LoginAdaptiveTokens.textPrimary()
    val textMuted = LoginAdaptiveTokens.textMuted()

    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text(placeholder, color = textMuted) },
        singleLine = true,
        visualTransformation = if (isPassword) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(imeAction = imeAction, keyboardType = keyboardType),
        keyboardActions = KeyboardActions(onAny = { onImeAction() }),
        textStyle = TextStyle(color = textPrimary, fontSize = 15.sp),
        colors =
        TextFieldDefaults.colors(
            focusedTextColor = textPrimary,
            unfocusedTextColor = textPrimary,
            focusedContainerColor = surfEl,
            unfocusedContainerColor = surfEl,
            disabledContainerColor = surfEl,
            focusedIndicatorColor = ember,
            unfocusedIndicatorColor = border,
            cursorColor = ember,
        ),
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(10.dp),
    )
}

@Composable
private fun EmailSubmitButton(title: String, isLoading: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val ember = LoginAdaptiveTokens.ember()
    val blaze = LoginAdaptiveTokens.blaze()

    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(Brush.horizontalGradient(colors = listOf(ember, blaze)))
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.5f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
        } else {
            Text(text = title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

// ── Wordmark ──
// iOS: .font(.system(.largeTitle, design: .rounded).weight(.bold))
// .foregroundStyle(MobileTheme.primaryGradient) — gradient text
// .tracking(-0.5)
// .shadow(color: ember.opacity(0.25), radius: 12, y: 4)
@OptIn(ExperimentalTextApi::class)
@Composable
internal fun Wordmark() {
    val gradient = LoginAdaptiveTokens.primaryGradient()
    val ember = LoginAdaptiveTokens.ember()
    val isDark = isSystemInDarkTheme()

    Text(
        text = "OpenBurnBar",
        fontSize = 34.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = (-0.5).sp,
        style = TextStyle(
            brush = gradient,
        ),
        modifier = Modifier
            .graphicsLayer {
                // Shadow matching iOS: ember color, radius 12, y offset 4
                shadowElevation = if (isDark) 12f else 8f
                shape = RoundedCornerShape(4.dp)
                clip = false
            },
    )
}

@Composable
internal fun Tagline() {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Your AI agents, in your pocket.",
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = LoginAdaptiveTokens.textPrimary().copy(alpha = 0.85f),
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(6.dp))
        Text(
            text = "Sign in with the same account you use on Mac.",
            fontSize = 13.sp,
            color = LoginAdaptiveTokens.textSecondary(),
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
internal fun EmailDiscloseLink(enabled: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val surfEl = LoginAdaptiveTokens.surfaceElevated()
    val border = LoginAdaptiveTokens.border()
    val textPrimary = LoginAdaptiveTokens.textPrimary()
    val isDark = isSystemInDarkTheme()

    Row(
        modifier =
        modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(surfEl.copy(alpha = if (isDark) 0.6f else 1f))
            .border(BorderStroke(1.dp, border), RoundedCornerShape(16.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.6f)
            .testTag("signIn.email.disclose"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Email,
            contentDescription = null,
            tint = textPrimary,
            modifier = Modifier.size(18.dp),
        )
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = "Sign in with email",
            color = textPrimary,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

// Keep the old object for backward compatibility but mark it as deprecated.
// All composables above now use LoginAdaptiveTokens instead.
@Deprecated("Use LoginAdaptiveTokens for adaptive light/dark support", ReplaceWith("LoginAdaptiveTokens"))
internal object LoginBrandTokens {
    val Ember = Color(0xFFFF6B35)
    val Amber = Color(0xFFFFA800)
    val Blaze = Color(0xFFE86100)
    val Background = Color(0xFF0D0D0D)
    val Surface = Color(0xFF161B22)
    val SurfaceElevated = Color(0xFF1F2630)
    val Border = Color(0xFF30363D)
    val TextPrimary = Color(0xFFE6EDF3)
    val TextSecondary = Color(0xFF8B949E)
    val TextMuted = Color(0xFF6E7681)
    val ErrorColor = Color(0xFFF45B69)
}

@Composable
internal fun LoginScreenRoot(
    userStore: UserStore,
    isSigningIn: Boolean,
    authError: AuthError?,
    onDismissError: () -> Unit,
) {
    val focus = LocalFocusManager.current
    var emailExpanded by remember { mutableStateOf(false) }
    var emailMode by remember { mutableStateOf(EmailMode.SignIn) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var inFlightProvider by remember { mutableStateOf<LoginProvider?>(null) }
    var appeared by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { appeared = true }

    LoginScreenGoogleAuthEffects(
        userStore = userStore,
        isSigningIn = isSigningIn,
        onInFlightProviderChange = { inFlightProvider = it },
    )

    // Entrance animation — matches iOS .opacity + .offset(y:16) with .easeOut(0.55)
    val entranceAlpha by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = tween(durationMillis = 550),
        label = "entrance-alpha",
    )
    val entranceY by animateFloatAsState(
        targetValue = if (appeared) 0f else 16f,
        animationSpec = tween(durationMillis = 550),
        label = "entrance-y",
    )

    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { focus.clearFocus() },
    ) {
        EmberBackdrop()
        Box(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    alpha = entranceAlpha
                    translationY = entranceY
                },
        ) {
            LoginScreenScrollContent(
                userStore = userStore,
                state =
                LoginScreenContentState(
                    inFlightProvider = inFlightProvider,
                    emailExpanded = emailExpanded,
                    emailMode = emailMode,
                    email = email,
                    password = password,
                    authError = authError,
                ),
                callbacks =
                LoginScreenContentCallbacks(
                    onSetInFlightProvider = { inFlightProvider = it },
                    onEmailExpandedChange = { emailExpanded = it },
                    onEmailModeChange = { emailMode = it },
                    onEmailChange = { email = it },
                    onPasswordChange = { password = it },
                    onDismissError = onDismissError,
                    onClearFocus = focus::clearFocus,
                ),
            )
        }
    }
}

@Composable
internal fun LoginScreenScrollContent(
    userStore: UserStore,
    state: LoginScreenContentState,
    callbacks: LoginScreenContentCallbacks,
) {
    val context = LocalContext.current
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // iOS: Spacer(minLength: MobileTheme.Spacing.lg) = 16
        Spacer(modifier = Modifier.height(16.dp))
        EmberLogo(modifier = Modifier.size(width = 184.dp, height = 132.dp))
        // iOS: .padding(.bottom, MobileTheme.Spacing.lg) = 16
        Spacer(modifier = Modifier.height(16.dp))
        Wordmark()
        // iOS: .padding(.bottom, MobileTheme.Spacing.sm) = 8
        Spacer(modifier = Modifier.height(8.dp))
        Tagline()
        // iOS: .padding(.bottom, MobileTheme.Spacing.xl) = 24
        Spacer(modifier = Modifier.height(24.dp))
        LoginProviderButtons(
            inFlightProvider = state.inFlightProvider,
            onSetInFlightProvider = callbacks.onSetInFlightProvider,
            userStore = userStore,
            activity = context as? Activity,
        )
        // iOS: .padding(.top, MobileTheme.Spacing.md) = 12
        Spacer(modifier = Modifier.height(12.dp))
        LoginEmailSection(state = state, callbacks = callbacks, userStore = userStore)
        LoginErrorSection(authError = state.authError, onDismissError = callbacks.onDismissError)
        Spacer(modifier = Modifier.weight(1f))
        PrivacyFooter()
        // iOS: .padding(.top, MobileTheme.Spacing.md) = 12, then Spacer(minLength: lg) = 16
        Spacer(modifier = Modifier.height(16.dp))
    }
}

@Composable
private fun LoginProviderButtons(
    inFlightProvider: LoginProvider?,
    onSetInFlightProvider: (LoginProvider?) -> Unit,
    userStore: UserStore,
    activity: Activity?,
) {
    Column(
        modifier = Modifier.widthIn(max = 360.dp).fillMaxWidth(),
        // iOS: VStack(spacing: MobileTheme.Spacing.md) = 12
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        AppleButton(
            isLoading = inFlightProvider == LoginProvider.Apple,
            enabled = inFlightProvider == null,
            onClick = {
                onSetInFlightProvider(LoginProvider.Apple)
                if (activity == null) {
                    onSetInFlightProvider(null)
                } else {
                    userStore.signInWithApple(activity)
                }
            },
        )
        GoogleButton(
            isLoading = inFlightProvider == LoginProvider.Google,
            enabled = inFlightProvider == null,
            onClick = {
                onSetInFlightProvider(LoginProvider.Google)
                if (activity == null) {
                    onSetInFlightProvider(null)
                } else {
                    userStore.signInWithGoogle(activity)
                }
            },
        )
        GitHubButton(
            isLoading = inFlightProvider == LoginProvider.GitHub,
            enabled = inFlightProvider == null,
            onClick = {
                onSetInFlightProvider(LoginProvider.GitHub)
                if (activity == null) {
                    onSetInFlightProvider(null)
                } else {
                    userStore.signInWithGitHub(activity)
                }
            },
        )
    }
}

@Composable
private fun LoginEmailSection(
    state: LoginScreenContentState,
    callbacks: LoginScreenContentCallbacks,
    userStore: UserStore,
) {
    AnimatedVisibility(visible = !state.emailExpanded, enter = fadeIn(), exit = fadeOut()) {
        EmailDiscloseLink(
            enabled = state.inFlightProvider == null,
            modifier = Modifier.widthIn(max = 360.dp).fillMaxWidth(),
            onClick = { callbacks.onEmailExpandedChange(true) },
        )
    }
    AnimatedVisibility(
        visible = state.emailExpanded,
        enter = fadeIn() + expandVertically(),
        exit = fadeOut() + shrinkVertically(),
    ) {
        EmailPane(
            state =
            EmailPaneState(
                mode = state.emailMode,
                email = state.email,
                password = state.password,
                isSubmitting = state.inFlightProvider == LoginProvider.Email,
                inFlight = state.inFlightProvider != null,
            ),
            modifier = Modifier.widthIn(max = 360.dp).fillMaxWidth(),
            callbacks =
            EmailPaneCallbacks(
                onModeChange = callbacks.onEmailModeChange,
                onEmailChange = callbacks.onEmailChange,
                onPasswordChange = callbacks.onPasswordChange,
                onClose = {
                    callbacks.onEmailExpandedChange(false)
                    callbacks.onClearFocus()
                },
                onSubmit = {
                    callbacks.onClearFocus()
                    callbacks.onSetInFlightProvider(LoginProvider.Email)
                    if (state.emailMode == EmailMode.SignIn) {
                        userStore.signInWithEmail(state.email, state.password)
                    } else {
                        userStore.signUpWithEmail(state.email, state.password)
                    }
                },
            ),
        )
    }
}

@Composable
private fun LoginErrorSection(authError: AuthError?, onDismissError: () -> Unit) {
    AnimatedVisibility(
        visible = authError != null,
        enter = fadeIn() + expandVertically(),
        exit = fadeOut() + shrinkVertically(),
    ) {
        authError?.let {
            ErrorBanner(
                error = it,
                modifier =
                Modifier
                    .widthIn(max = 360.dp)
                    .fillMaxWidth()
                    .padding(top = 16.dp),
                onDismiss = onDismissError,
            )
        }
    }
}

// ── Apple Button ──
// iOS: uses Apple's SignInWithAppleButton — white in dark mode, black in light mode.
// Height 52dp, cornerRadius 16 (MobileTheme.Radius.lg), shadow with ember tint.
@Composable
private fun AppleButton(isLoading: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val isDark = isSystemInDarkTheme()
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val ember = LoginAdaptiveTokens.ember()

    // Press feedback matching iOS EmberPressButtonStyle
    val pressScale by animateFloatAsState(
        targetValue = if (isPressed) 0.98f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "apple-press-scale",
    )

    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .scale(pressScale)
            .shadow(
                elevation = if (isPressed) 4.dp else 14.dp,
                shape = RoundedCornerShape(16.dp),
                ambientColor = if (isDark) ember.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.10f),
                spotColor = if (isDark) ember.copy(alpha = 0.18f) else Color.Black.copy(alpha = 0.20f),
            )
            .clip(RoundedCornerShape(16.dp))
            .background(if (isDark) Color.White else Color.Black)
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled,
                onClick = onClick,
            )
            .padding(horizontal = 16.dp)
            .alpha(if (enabled) 1f else 0.6f)
            .testTag("signIn.apple")
            .semantics { contentDescription = "Continue with Apple" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        val fg = if (isDark) Color.Black else Color.White
        if (isLoading) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = fg, strokeWidth = 2.dp)
            Spacer(modifier = Modifier.width(12.dp))
        } else {
            Image(
                painter = painterResource(id = R.drawable.logo_apple),
                contentDescription = null,
                colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(fg),
                modifier = Modifier.size(18.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
        }
        Text(text = "Continue with Apple", color = fg, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun GitHubButton(isLoading: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val isDark = isSystemInDarkTheme()
    val surfEl = LoginAdaptiveTokens.surfaceElevated()
    val border = LoginAdaptiveTokens.border()
    val textPrimary = LoginAdaptiveTokens.textPrimary()
    val ember = LoginAdaptiveTokens.ember()

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()

    val pressScale by animateFloatAsState(
        targetValue = if (isPressed) 0.98f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "github-press-scale",
    )

    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .scale(pressScale)
            .shadow(
                elevation = if (isPressed) 4.dp else 14.dp,
                shape = RoundedCornerShape(16.dp),
                ambientColor = if (isDark) ember.copy(alpha = if (isPressed) 0.10f else 0.18f) else Color.Black.copy(alpha = 0.06f),
                spotColor = if (isDark) ember.copy(alpha = if (isPressed) 0.10f else 0.18f) else Color.Black.copy(alpha = 0.12f),
            )
            .clip(RoundedCornerShape(16.dp))
            .background(surfEl)
            .border(BorderStroke(1.dp, border), RoundedCornerShape(16.dp))
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled,
                onClick = onClick,
            )
            .padding(horizontal = 16.dp)
            .alpha(if (enabled) 1f else 0.6f)
            .testTag("signIn.github")
            .semantics { contentDescription = "Continue with GitHub" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = textPrimary, strokeWidth = 2.dp)
            Spacer(modifier = Modifier.width(12.dp))
        } else {
            Image(
                painter = painterResource(id = R.drawable.github_logo),
                contentDescription = null,
                modifier = Modifier.size(20.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
        }
        Text(text = "Continue with GitHub", color = textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}
@Composable
private fun GoogleButton(isLoading: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val isDark = isSystemInDarkTheme()
    val surfEl = LoginAdaptiveTokens.surfaceElevated()
    val border = LoginAdaptiveTokens.border()
    val textPrimary = LoginAdaptiveTokens.textPrimary()
    val ember = LoginAdaptiveTokens.ember()

    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()

    // Press feedback matching iOS EmberPressButtonStyle
    val pressScale by animateFloatAsState(
        targetValue = if (isPressed) 0.98f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "google-press-scale",
    )

    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .scale(pressScale)
            .shadow(
                elevation = if (isPressed) 4.dp else 14.dp,
                shape = RoundedCornerShape(16.dp),
                ambientColor = if (isDark) ember.copy(alpha = if (isPressed) 0.10f else 0.18f) else Color.Black.copy(alpha = 0.06f),
                spotColor = if (isDark) ember.copy(alpha = if (isPressed) 0.10f else 0.18f) else Color.Black.copy(alpha = 0.12f),
            )
            .clip(RoundedCornerShape(16.dp))
            .background(surfEl)
            .border(BorderStroke(1.dp, border), RoundedCornerShape(16.dp))
            .clickable(
                interactionSource = interactionSource,
                indication = null,
                enabled = enabled,
                onClick = onClick,
            )
            .padding(horizontal = 16.dp)
            .alpha(if (enabled) 1f else 0.6f)
            .testTag("signIn.google")
            .semantics { contentDescription = "Continue with Google" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = textPrimary, strokeWidth = 2.dp)
            Spacer(modifier = Modifier.width(12.dp))
        } else {
            GoogleGlyph(modifier = Modifier.size(20.dp))
            Spacer(modifier = Modifier.width(10.dp))
        }
        Text(text = "Continue with Google", color = textPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun GoogleGlyph(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val w = size.width
        val h = size.height
        val stroke = w * 0.16f
        drawArc(
            color = Color(0xFFEA4335),
            startAngle = 200f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawArc(
            color = Color(0xFFFBBC05),
            startAngle = 110f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawArc(
            color = Color(0xFF34A853),
            startAngle = 20f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawArc(
            color = Color(0xFF4285F4),
            startAngle = -70f,
            sweepAngle = 100f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawRect(
            color = Color(0xFF4285F4),
            topLeft = Offset(w * 0.50f, h * 0.43f),
            size = Size(w * 0.42f, stroke * 0.85f),
        )
    }
}

@Composable
private fun ErrorBanner(error: AuthError, modifier: Modifier = Modifier, onDismiss: () -> Unit) {
    val errorColor = LoginAdaptiveTokens.errorColor()
    val textPrimary = LoginAdaptiveTokens.textPrimary()
    val textSecondary = LoginAdaptiveTokens.textSecondary()
    val textMuted = LoginAdaptiveTokens.textMuted()

    Row(
        modifier =
        modifier
            .clip(RoundedCornerShape(10.dp))
            .background(errorColor.copy(alpha = 0.10f))
            .border(BorderStroke(1.dp, errorColor.copy(alpha = 0.35f)), RoundedCornerShape(10.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.WarningAmber,
            contentDescription = null,
            tint = errorColor,
            modifier = Modifier.size(18.dp).padding(top = 2.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Sign-in problem",
                color = textPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = error.message,
                color = textSecondary,
                fontSize = 13.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Dismiss",
                tint = textMuted,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

@Composable
private fun PrivacyFooter() {
    Text(
        text = "Encrypted · Local-first · Your stats never leave your account.",
        color = LoginAdaptiveTokens.textMuted(),
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        textAlign = TextAlign.Center,
    )
}
