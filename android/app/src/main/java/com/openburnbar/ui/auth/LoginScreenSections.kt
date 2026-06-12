package com.openburnbar.ui.auth

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import android.app.Activity
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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
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

private val LOGIN_ERROR_DARK_COLOR = Color(0xFFFA5053)
private val LOGIN_ERROR_LIGHT_COLOR = Color(0xFFD43030)
private const val LOGIN_FLAME_FULL_WAVE = 2.0
private const val LOGIN_FLAME_FLICKER_PRIMARY_HZ = 0.9
private const val LOGIN_FLAME_FLICKER_SECONDARY_HZ = 2.1
private const val LOGIN_FLAME_FLICKER_TERTIARY_HZ = 3.7
private const val LOGIN_FLAME_FLICKER_SECONDARY_PHASE = 1.7
private const val LOGIN_FLAME_FLICKER_TERTIARY_PHASE = 0.4
private const val LOGIN_FLAME_FLICKER_PRIMARY_WEIGHT = 0.5
private const val LOGIN_FLAME_FLICKER_SECONDARY_WEIGHT = 0.3
private const val LOGIN_FLAME_FLICKER_TERTIARY_WEIGHT = 0.2
private const val LOGIN_FLAME_INTENSITY_BASE = 0.5
private const val LOGIN_FLAME_LEAN_PRIMARY_HZ = 0.45
private const val LOGIN_FLAME_LEAN_SECONDARY_HZ = 0.27
private const val LOGIN_FLAME_LEAN_PRIMARY_PHASE = 0.9
private const val LOGIN_FLAME_LEAN_PRIMARY_WEIGHT = 0.6
private const val LOGIN_FLAME_LEAN_SECONDARY_WEIGHT = 0.4
private const val LOGIN_FLAME_LEAN_DEGREES = 1.4
private const val LOGIN_FLAME_STRETCH_BASE = 1.0f
private const val LOGIN_FLAME_STRETCH_SCALE = 0.07f
private const val LOGIN_FLAME_SQUEEZE_SCALE = 0.025f
private const val LOGIN_FLAME_HALO_SCALE_BASE = 0.95f
private const val LOGIN_FLAME_HALO_SCALE_RANGE = 0.18f
private const val LOGIN_FLAME_HALO_OPACITY_BASE = 0.55f
private const val LOGIN_FLAME_HALO_OPACITY_RANGE = 0.40f
private const val LOGIN_FLAME_TRANSFORM_ORIGIN_X = 0.5f
private const val LOGIN_FLAME_TRANSFORM_ORIGIN_Y = 1.0f
private const val LOGIN_PRIMARY_DISABLED_ALPHA = 0.5f
private const val LOGIN_BUTTON_DISABLED_ALPHA = 0.6f
private const val LOGIN_BUTTON_DARK_SURFACE_ALPHA = 0.6f
private const val LOGIN_BUTTON_DARK_SHADOW_ELEVATION = 12f
private const val LOGIN_BUTTON_LIGHT_SHADOW_ELEVATION = 8f
private const val LOGIN_BUTTON_SHADOW_RADIUS_DP = 4
private const val GOOGLE_GLYPH_STROKE_FRACTION = 0.16f
private const val GOOGLE_GLYPH_RED_START = 200f
private const val GOOGLE_GLYPH_YELLOW_START = 110f
private const val GOOGLE_GLYPH_GREEN_START = 20f
private const val GOOGLE_GLYPH_BLUE_START = -70f
private const val GOOGLE_GLYPH_STANDARD_SWEEP = 90f
private const val GOOGLE_GLYPH_BLUE_SWEEP = 100f
private const val GOOGLE_GLYPH_BAR_X = 0.50f
private const val GOOGLE_GLYPH_BAR_Y = 0.43f
private const val GOOGLE_GLYPH_BAR_WIDTH = 0.42f
private const val GOOGLE_GLYPH_BAR_HEIGHT = 0.85f
private val GOOGLE_GLYPH_RED = Color(0xFFEA4335)
private val GOOGLE_GLYPH_YELLOW = Color(0xFFFBBC05)
private val GOOGLE_GLYPH_GREEN = Color(0xFF34A853)
private val GOOGLE_GLYPH_BLUE = Color(0xFF4285F4)

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
    @Composable fun errorColor(): Color = if (isSystemInDarkTheme()) LOGIN_ERROR_DARK_COLOR else LOGIN_ERROR_LIGHT_COLOR
}

private fun loginFlameWave(time: Double, frequency: Double, phase: Double = 0.0): Double =
    sin(time * LOGIN_FLAME_FULL_WAVE * PI * frequency + phase)

internal object LoginAdaptiveGradientTokens {
    // iOS: primaryGradient = LinearGradient(ember → amber → blaze)
    @Composable fun primaryGradient(): Brush = Brush.horizontalGradient(
        colors = listOf(LoginAdaptiveTokens.ember(), LoginAdaptiveTokens.amber(), LoginAdaptiveTokens.blaze()),
    )
}

internal object LoginAdaptiveTextTokens {
    @Composable fun secondary(): Color = if (isSystemInDarkTheme()) AuroraColors.darkTextSecondary else AuroraColors.lightTextSecondary
    @Composable fun muted(): Color = if (isSystemInDarkTheme()) AuroraColors.darkTextMuted else AuroraColors.lightTextMuted
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
    isSigningIn: Boolean,
    onInFlightProviderChange: (LoginProvider?) -> Unit,
) {
    LaunchedEffect(isSigningIn) {
        if (!isSigningIn) onInFlightProviderChange(null)
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
    val f1 = loginFlameWave(t, LOGIN_FLAME_FLICKER_PRIMARY_HZ)
    val f2 = loginFlameWave(t, LOGIN_FLAME_FLICKER_SECONDARY_HZ, LOGIN_FLAME_FLICKER_SECONDARY_PHASE)
    val f3 = loginFlameWave(t, LOGIN_FLAME_FLICKER_TERTIARY_HZ, LOGIN_FLAME_FLICKER_TERTIARY_PHASE)
    val flicker =
        f1 * LOGIN_FLAME_FLICKER_PRIMARY_WEIGHT +
            f2 * LOGIN_FLAME_FLICKER_SECONDARY_WEIGHT +
            f3 * LOGIN_FLAME_FLICKER_TERTIARY_WEIGHT
    val intensity = (LOGIN_FLAME_INTENSITY_BASE + LOGIN_FLAME_INTENSITY_BASE * flicker).toFloat()

    // --- Lateral lean: two slow incommensurate sines (iOS: 0.45Hz + 0.27Hz) ---
    val leanRaw =
        loginFlameWave(t, LOGIN_FLAME_LEAN_PRIMARY_HZ, LOGIN_FLAME_LEAN_PRIMARY_PHASE) * LOGIN_FLAME_LEAN_PRIMARY_WEIGHT +
            loginFlameWave(t, LOGIN_FLAME_LEAN_SECONDARY_HZ) * LOGIN_FLAME_LEAN_SECONDARY_WEIGHT
    val leanDegrees = (leanRaw * LOGIN_FLAME_LEAN_DEGREES).toFloat()

    // --- Vertical lick: anchored at bottom, flame stretches upward ---
    val stretchY = LOGIN_FLAME_STRETCH_BASE + intensity * LOGIN_FLAME_STRETCH_SCALE
    val squeezeX = LOGIN_FLAME_STRETCH_BASE - intensity * LOGIN_FLAME_SQUEEZE_SCALE

    // --- Halo: tracks flicker intensity (iOS halo) ---
    val haloScale = LOGIN_FLAME_HALO_SCALE_BASE + intensity * LOGIN_FLAME_HALO_SCALE_RANGE
    val haloOpacity = LOGIN_FLAME_HALO_OPACITY_BASE + intensity * LOGIN_FLAME_HALO_OPACITY_RANGE

    val ember = LoginAdaptiveTokens.ember()
    val amber = LoginAdaptiveTokens.amber()

    Box(
        modifier = modifier.semantics { contentDescription = "OpenBurnBar logo" },
        contentAlignment = Alignment.Center,
    ) {
        EmberLogoHalo(ember = ember, amber = amber, haloScale = haloScale, haloOpacity = haloOpacity)
        EmberLogoImage(squeezeX = squeezeX, stretchY = stretchY, leanDegrees = leanDegrees)
    }
}

@Composable
private fun EmberLogoHalo(
    ember: Color,
    amber: Color,
    haloScale: Float,
    haloOpacity: Float,
) {
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
}

@Composable
private fun EmberLogoImage(
    squeezeX: Float,
    stretchY: Float,
    leanDegrees: Float,
) {
    Box(
        modifier = Modifier
            .size(132.dp)
            .graphicsLayer {
                scaleX = squeezeX
                scaleY = stretchY
                rotationZ = leanDegrees
                transformOrigin = androidx.compose.ui.graphics.TransformOrigin(LOGIN_FLAME_TRANSFORM_ORIGIN_X, LOGIN_FLAME_TRANSFORM_ORIGIN_Y)
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
                tint = LoginAdaptiveTextTokens.muted(),
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
    val textMuted = LoginAdaptiveTextTokens.muted()

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
            .alpha(if (enabled) 1f else LOGIN_PRIMARY_DISABLED_ALPHA),
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
    val gradient = LoginAdaptiveGradientTokens.primaryGradient()
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
                shadowElevation = if (isDark) LOGIN_BUTTON_DARK_SHADOW_ELEVATION else LOGIN_BUTTON_LIGHT_SHADOW_ELEVATION
                shape = RoundedCornerShape(LOGIN_BUTTON_SHADOW_RADIUS_DP.dp)
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
            color = LoginAdaptiveTextTokens.secondary(),
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
            .background(surfEl.copy(alpha = if (isDark) LOGIN_BUTTON_DARK_SURFACE_ALPHA else 1f))
            .border(BorderStroke(1.dp, border), RoundedCornerShape(16.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else LOGIN_BUTTON_DISABLED_ALPHA)
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
        isSigningIn = isSigningIn,
        onInFlightProviderChange = { inFlightProvider = it },
    )

    val entrance = rememberLoginEntranceMotion(appeared)
    val contentState = LoginScreenContentState(inFlightProvider, emailExpanded, emailMode, email, password, authError)
    val contentCallbacks = LoginScreenContentCallbacks(
        onSetInFlightProvider = { inFlightProvider = it },
        onEmailExpandedChange = { emailExpanded = it },
        onEmailModeChange = { emailMode = it },
        onEmailChange = { email = it },
        onPasswordChange = { password = it },
        onDismissError = onDismissError,
        onClearFocus = focus::clearFocus,
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
                    alpha = entrance.alpha
                    translationY = entrance.y
                },
        ) {
            LoginScreenScrollContent(
                userStore = userStore,
                state = contentState,
                callbacks = contentCallbacks,
            )
        }
    }
}

private data class LoginEntranceMotion(
    val alpha: Float,
    val y: Float,
)

@Composable
private fun rememberLoginEntranceMotion(appeared: Boolean): LoginEntranceMotion {
    val alpha by animateFloatAsState(
        targetValue = if (appeared) 1f else 0f,
        animationSpec = tween(durationMillis = 550),
        label = "entrance-alpha",
    )
    val y by animateFloatAsState(
        targetValue = if (appeared) 0f else 16f,
        animationSpec = tween(durationMillis = 550),
        label = "entrance-y",
    )
    return LoginEntranceMotion(alpha = alpha, y = y)
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
            .alpha(if (enabled) 1f else LOGIN_BUTTON_DISABLED_ALPHA)
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
            .alpha(if (enabled) 1f else LOGIN_BUTTON_DISABLED_ALPHA)
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
            .alpha(if (enabled) 1f else LOGIN_BUTTON_DISABLED_ALPHA)
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
        val stroke = w * GOOGLE_GLYPH_STROKE_FRACTION
        drawArc(
            color = GOOGLE_GLYPH_RED,
            startAngle = GOOGLE_GLYPH_RED_START,
            sweepAngle = GOOGLE_GLYPH_STANDARD_SWEEP,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawArc(
            color = GOOGLE_GLYPH_YELLOW,
            startAngle = GOOGLE_GLYPH_YELLOW_START,
            sweepAngle = GOOGLE_GLYPH_STANDARD_SWEEP,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawArc(
            color = GOOGLE_GLYPH_GREEN,
            startAngle = GOOGLE_GLYPH_GREEN_START,
            sweepAngle = GOOGLE_GLYPH_STANDARD_SWEEP,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawArc(
            color = GOOGLE_GLYPH_BLUE,
            startAngle = GOOGLE_GLYPH_BLUE_START,
            sweepAngle = GOOGLE_GLYPH_BLUE_SWEEP,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = Size(w - stroke, h - stroke),
            style = Stroke(width = stroke),
        )
        drawRect(
            color = GOOGLE_GLYPH_BLUE,
            topLeft = Offset(w * GOOGLE_GLYPH_BAR_X, h * GOOGLE_GLYPH_BAR_Y),
            size = Size(w * GOOGLE_GLYPH_BAR_WIDTH, stroke * GOOGLE_GLYPH_BAR_HEIGHT),
        )
    }
}

@Composable
private fun ErrorBanner(error: AuthError, modifier: Modifier = Modifier, onDismiss: () -> Unit) {
    val errorColor = LoginAdaptiveTokens.errorColor()
    val textPrimary = LoginAdaptiveTokens.textPrimary()
    val textSecondary = LoginAdaptiveTextTokens.secondary()
    val textMuted = LoginAdaptiveTextTokens.muted()

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
        color = LoginAdaptiveTextTokens.muted(),
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        textAlign = TextAlign.Center,
    )
}
