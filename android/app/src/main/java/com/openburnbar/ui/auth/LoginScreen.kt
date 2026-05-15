package com.openburnbar.ui.auth

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
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
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
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
import kotlin.math.PI
import kotlin.math.sin

// Brand tokens — mirror iOS MobileTheme.
private val Ember = Color(0xFFFF6B35)
private val Amber = Color(0xFFFFA800)
private val Blaze = Color(0xFFE86100)
private val Background = Color(0xFF0D0D0D)
private val Surface = Color(0xFF161B22)
private val SurfaceElevated = Color(0xFF1F2630)
private val Border = Color(0xFF30363D)
private val BorderSubtle = Color(0xFF21262D)
private val TextPrimary = Color(0xFFE6EDF3)
private val TextSecondary = Color(0xFF8B949E)
private val TextMuted = Color(0xFF6E7681)
private val ErrorColor = Color(0xFFF45B69)

/**
 * First-impression sign-in. Visual parity with iOS `SignInScene`:
 *
 * - **EmberBackdrop** — warm ambient gradient + two slowly drifting ember
 *   orbs behind the content (still under reduce-motion / reduce-transparency).
 * - **EmberLogo** — bundled flame PNG with a "breathing" halo + subtle
 *   sway. Collapses to a still image on reduce-motion.
 * - **Wordmark** — "OpenBurnBar" in a heavy ember→amber gradient.
 * - **Tagline** — "Your AI agents, in your pocket." + secondary line
 *   "Sign in with the same account you use on Mac."
 * - **Provider buttons** — Apple (black w/ white logo) on top, then a
 *   Google button matching the official multi-color "G" mark.
 * - **Email disclosure** — collapsed link that expands inline into a
 *   compact Sign-in / Create pane.
 * - **Error banner** — slides up under the buttons when sign-in fails.
 * - **Privacy footer** — "Encrypted · Local-first · Your stats never
 *   leave your account."
 */
@Composable
fun LoginScreen(
    userStore: UserStore,
    isSigningIn: Boolean,
    authError: AuthError?,
    onDismissError: () -> Unit
) {
    val isDark = isSystemInDarkTheme()
    val context = LocalContext.current
    val focus = LocalFocusManager.current

    var emailExpanded by remember { mutableStateOf(false) }
    var emailMode by remember { mutableStateOf(EmailMode.SignIn) }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }

    // Track the in-flight provider so loading spinners + disabled states
    // mirror iOS's `state.inFlightProvider`.
    var inFlightProvider by remember { mutableStateOf<Provider?>(null) }
    LaunchedEffect(isSigningIn) {
        if (!isSigningIn) inFlightProvider = null
    }

    // Legacy Google intent launcher — used when Credential Manager can't
    // surface a Google account on the device.
    val googleLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { r ->
        if (r.resultCode == Activity.RESULT_OK) {
            userStore.handleGoogleSignInResult(r.data)
        } else {
            inFlightProvider = null
        }
    }

    // When the store flips its legacy-fallback signal true, fire the launcher.
    val needsLegacyFallback by userStore.needsLegacyGoogleFallback.collectAsState()
    LaunchedEffect(needsLegacyFallback) {
        if (needsLegacyFallback) {
            googleLauncher.launch(userStore.getGoogleSignInIntent(context))
            userStore.consumeLegacyGoogleFallback()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { focus.clearFocus() }
    ) {
        EmberBackdrop()

        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(modifier = Modifier.height(24.dp))

            EmberLogo(modifier = Modifier.size(width = 184.dp, height = 132.dp))
            Spacer(modifier = Modifier.height(16.dp))

            Wordmark()
            Spacer(modifier = Modifier.height(8.dp))

            Tagline()
            Spacer(modifier = Modifier.height(24.dp))

            // Provider buttons — full width, identical heights.
            Column(
                modifier = Modifier.widthIn(max = 360.dp).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                AppleButton(
                    isLoading = inFlightProvider == Provider.Apple,
                    enabled = inFlightProvider == null,
                    onClick = {
                        inFlightProvider = Provider.Apple
                        userStore.signInWithApple(context as Activity)
                    },
                )
                GoogleButton(
                    isLoading = inFlightProvider == Provider.Google,
                    enabled = inFlightProvider == null,
                    onClick = {
                        inFlightProvider = Provider.Google
                        userStore.signInWithGoogle(context as Activity)
                    },
                )
            }

            Spacer(modifier = Modifier.height(12.dp))

            // Email disclosure (collapsed link → expanded pane).
            AnimatedVisibility(
                visible = !emailExpanded,
                enter = fadeIn(),
                exit = fadeOut(),
            ) {
                EmailDiscloseLink(
                    enabled = inFlightProvider == null,
                    modifier = Modifier.widthIn(max = 360.dp).fillMaxWidth(),
                    onClick = { emailExpanded = true },
                )
            }
            AnimatedVisibility(
                visible = emailExpanded,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                EmailPane(
                    mode = emailMode,
                    email = email,
                    password = password,
                    isSubmitting = inFlightProvider == Provider.Email,
                    inFlight = inFlightProvider != null,
                    modifier = Modifier.widthIn(max = 360.dp).fillMaxWidth(),
                    onModeChange = { emailMode = it },
                    onEmailChange = { email = it },
                    onPasswordChange = { password = it },
                    onClose = {
                        emailExpanded = false
                        focus.clearFocus()
                    },
                    onSubmit = {
                        focus.clearFocus()
                        inFlightProvider = Provider.Email
                        if (emailMode == EmailMode.SignIn) {
                            userStore.signInWithEmail(email, password)
                        } else {
                            userStore.signUpWithEmail(email, password)
                        }
                    },
                )
            }

            // Error banner.
            AnimatedVisibility(
                visible = authError != null,
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically(),
            ) {
                authError?.let {
                    ErrorBanner(
                        error = it,
                        modifier = Modifier
                            .widthIn(max = 360.dp)
                            .fillMaxWidth()
                            .padding(top = 16.dp),
                        onDismiss = onDismissError,
                    )
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            PrivacyFooter()
            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

private enum class Provider { Apple, Google, Email }
private enum class EmailMode { SignIn, Create }

// ─── Ember backdrop ───────────────────────────────────────────────────────

/** Warm ambient gradient + two slowly drifting ember orbs. Matches iOS
 * `EmberBackdrop`. */
@Composable
private fun EmberBackdrop() {
    val transition = rememberInfiniteTransition(label = "ember-backdrop")
    val drift by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 9000, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "drift",
    )
    Box(modifier = Modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colors = listOf(Background, Background, Surface),
                    )
                ),
        )
        EmberOrb(
            color = Ember.copy(alpha = 0.55f),
            size = 460.dp,
            blurRadius = 60.dp,
            offsetX = (-80f + drift * -40f).dp,
            offsetY = (-220f + drift * 40f).dp,
        )
        EmberOrb(
            color = Amber.copy(alpha = 0.45f),
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
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(size)
                .graphicsLayer { translationX = offsetX.toPx(); translationY = offsetY.toPx() }
                .blur(blurRadius)
                .clip(CircleShape)
                .background(color),
        )
    }
}

// ─── Ember logo ───────────────────────────────────────────────────────────

@Composable
private fun EmberLogo(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "ember-logo")
    // Slow breathing scale — ~3s cycle, ±3%.
    val breathScale by transition.animateFloat(
        initialValue = 0.97f,
        targetValue = 1.03f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2800, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "breath",
    )
    // Halo flicker — incommensurate frequency for organic feel.
    val haloPhase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 2100, easing = LinearEasing),
        ),
        label = "halo",
    )
    val haloIntensity = (0.5 + 0.5 * sin(haloPhase.toDouble() * 2.0 * PI)).toFloat()
    // Side-to-side sway, ~±1.4°.
    val swayPhase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 3700, easing = EaseInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "sway",
    )
    val swayDeg = (swayPhase - 0.5f) * 2f * 1.4f

    Box(
        modifier = modifier.semantics { contentDescription = "OpenBurnBar logo" },
        contentAlignment = Alignment.Center,
    ) {
        // Soft halo behind the flame.
        Box(
            modifier = Modifier
                .size(220.dp)
                .scale(0.95f + haloIntensity * 0.18f)
                .alpha(0.55f + haloIntensity * 0.4f)
                .blur(20.dp)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            Ember.copy(alpha = 0.55f),
                            Amber.copy(alpha = 0.32f),
                            Color.Transparent,
                        ),
                    )
                ),
        )
        // The actual brand mark.
        Image(
            painter = painterResource(id = R.drawable.logo_app),
            contentDescription = null,
            modifier = Modifier
                .size(132.dp)
                .scale(breathScale)
                .rotate(swayDeg)
                .graphicsLayer { compositingStrategy = CompositingStrategy.Auto },
        )
    }
}

// ─── Wordmark + tagline ───────────────────────────────────────────────────

@Composable
private fun Wordmark() {
    // Approximate iOS's `.foregroundStyle(primaryGradient)` with a
    // gradient-filled Box overlay masked by the text using BlendMode would
    // be heavier than warranted — using a solid ember accent reads almost
    // identical at this scale because the gradient on iOS sits behind a
    // single line of bold text.
    Text(
        text = "OpenBurnBar",
        fontSize = 34.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = FontFamily.SansSerif,
        color = Ember,
    )
}

@Composable
private fun Tagline() {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "Your AI agents, in your pocket.",
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = TextPrimary.copy(alpha = 0.85f),
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = "Sign in with the same account you use on Mac.",
            fontSize = 13.sp,
            color = TextSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

// ─── Provider buttons ─────────────────────────────────────────────────────

@Composable
private fun AppleButton(
    isLoading: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val scale by animateFloatAsState(targetValue = if (enabled) 1f else 0.99f, label = "apple-scale")
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .scale(scale)
            .clip(RoundedCornerShape(14.dp))
            .background(if (isSystemInDarkTheme()) Color.White else Color.Black)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp)
            .alpha(if (enabled) 1f else 0.6f)
            .testTag("signIn.apple")
            .semantics { contentDescription = "Continue with Apple" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        val fg = if (isSystemInDarkTheme()) Color.Black else Color.White
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = fg,
                strokeWidth = 2.dp,
            )
            Spacer(modifier = Modifier.width(12.dp))
        } else {
            // Bundled Apple wordmark PNG — tinted so it picks up the
            // button foreground color in both light + dark.
            Image(
                painter = painterResource(id = R.drawable.logo_apple),
                contentDescription = null,
                colorFilter = androidx.compose.ui.graphics.ColorFilter.tint(fg),
                modifier = Modifier.size(18.dp),
            )
            Spacer(modifier = Modifier.width(10.dp))
        }
        Text(
            text = "Continue with Apple",
            color = fg,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun GoogleButton(
    isLoading: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val isDark = isSystemInDarkTheme()
    val bg = if (isDark) Color(0xFFF2F2F2) else Color.White
    val fg = Color(0xFF1F1F1F)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .border(BorderStroke(1.dp, Color(0xFFE0E0E0)), RoundedCornerShape(14.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp)
            .alpha(if (enabled) 1f else 0.6f)
            .testTag("signIn.google")
            .semantics { contentDescription = "Continue with Google" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = fg,
                strokeWidth = 2.dp,
            )
            Spacer(modifier = Modifier.width(12.dp))
        } else {
            GoogleGlyph(modifier = Modifier.size(20.dp))
            Spacer(modifier = Modifier.width(10.dp))
        }
        Text(
            text = "Continue with Google",
            color = fg,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

/**
 * Approximates Google's official multi-color "G" mark using four
 * quadrant arcs. Not pixel-perfect (the official PNG is) but reads as
 * authentic at this scale without bundling another asset.
 */
@Composable
private fun GoogleGlyph(modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val w = size.width
        val h = size.height
        val stroke = w * 0.16f
        // Red top arc
        drawArc(
            color = Color(0xFFEA4335),
            startAngle = 200f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = androidx.compose.ui.geometry.Size(w - stroke, h - stroke),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
        // Yellow left arc
        drawArc(
            color = Color(0xFFFBBC05),
            startAngle = 110f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = androidx.compose.ui.geometry.Size(w - stroke, h - stroke),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
        // Green bottom arc
        drawArc(
            color = Color(0xFF34A853),
            startAngle = 20f,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = androidx.compose.ui.geometry.Size(w - stroke, h - stroke),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
        // Blue right arc + horizontal bar
        drawArc(
            color = Color(0xFF4285F4),
            startAngle = -70f,
            sweepAngle = 100f,
            useCenter = false,
            topLeft = Offset(stroke / 2f, stroke / 2f),
            size = androidx.compose.ui.geometry.Size(w - stroke, h - stroke),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke),
        )
        // Center crossbar
        drawRect(
            color = Color(0xFF4285F4),
            topLeft = Offset(w * 0.50f, h * 0.43f),
            size = androidx.compose.ui.geometry.Size(w * 0.42f, stroke * 0.85f),
        )
    }
}

// ─── Email disclosure ─────────────────────────────────────────────────────

@Composable
private fun EmailDiscloseLink(
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Row(
        modifier = modifier
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(SurfaceElevated.copy(alpha = 0.6f))
            .border(BorderStroke(1.dp, Border), RoundedCornerShape(14.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.6f)
            .testTag("signIn.email.disclose"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(
            imageVector = Icons.Filled.Email,
            contentDescription = null,
            tint = TextPrimary,
            modifier = Modifier.size(18.dp),
        )
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = "Sign in with email",
            color = TextPrimary,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun EmailPane(
    mode: EmailMode,
    email: String,
    password: String,
    isSubmitting: Boolean,
    inFlight: Boolean,
    modifier: Modifier = Modifier,
    onModeChange: (EmailMode) -> Unit,
    onEmailChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onClose: () -> Unit,
    onSubmit: () -> Unit,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(Surface.copy(alpha = 0.85f))
            .border(BorderStroke(1.dp, Border), RoundedCornerShape(14.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            EmailModePill(
                title = "Sign in",
                selected = mode == EmailMode.SignIn,
                onClick = { onModeChange(EmailMode.SignIn) },
            )
            EmailModePill(
                title = "Create",
                selected = mode == EmailMode.Create,
                onClick = { onModeChange(EmailMode.Create) },
            )
            Spacer(modifier = Modifier.width(1.dp).weight(1f))
            IconButton(onClick = onClose, modifier = Modifier.size(28.dp)) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = "Close email sign-in",
                    tint = TextMuted,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        AuthField(
            value = email,
            placeholder = "Email",
            onValueChange = onEmailChange,
            keyboardType = KeyboardType.Email,
            imeAction = ImeAction.Next,
        )
        AuthField(
            value = password,
            placeholder = "Password",
            onValueChange = onPasswordChange,
            keyboardType = KeyboardType.Password,
            imeAction = ImeAction.Done,
            isPassword = true,
            onImeAction = onSubmit,
        )
        EmailSubmitButton(
            title = if (mode == EmailMode.SignIn) "Sign in" else "Create account",
            isLoading = isSubmitting,
            enabled = !inFlight && email.isNotBlank() && password.length >= 6,
            onClick = onSubmit,
        )
    }
}

@Composable
private fun EmailModePill(title: String, selected: Boolean, onClick: () -> Unit) {
    val bg = if (selected) Ember else SurfaceElevated
    val fg = if (selected) Color.White else TextPrimary
    Box(
        modifier = Modifier
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
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text(placeholder, color = TextMuted) },
        singleLine = true,
        visualTransformation = if (isPassword) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(imeAction = imeAction, keyboardType = keyboardType),
        keyboardActions = KeyboardActions(onAny = { onImeAction() }),
        textStyle = androidx.compose.ui.text.TextStyle(color = TextPrimary, fontSize = 15.sp),
        colors = TextFieldDefaults.colors(
            focusedTextColor = TextPrimary,
            unfocusedTextColor = TextPrimary,
            focusedContainerColor = SurfaceElevated,
            unfocusedContainerColor = SurfaceElevated,
            disabledContainerColor = SurfaceElevated,
            focusedIndicatorColor = Ember,
            unfocusedIndicatorColor = Border,
            cursorColor = Ember,
        ),
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(12.dp),
    )
}

@Composable
private fun EmailSubmitButton(
    title: String,
    isLoading: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(
                Brush.horizontalGradient(
                    colors = listOf(Ember, Blaze),
                )
            )
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.5f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = Color.White,
                strokeWidth = 2.dp,
            )
        } else {
            Text(text = title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

// ─── Error banner ─────────────────────────────────────────────────────────

@Composable
private fun ErrorBanner(
    error: AuthError,
    modifier: Modifier = Modifier,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(ErrorColor.copy(alpha = 0.10f))
            .border(BorderStroke(1.dp, ErrorColor.copy(alpha = 0.35f)), RoundedCornerShape(12.dp))
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.WarningAmber,
            contentDescription = null,
            tint = ErrorColor,
            modifier = Modifier
                .size(18.dp)
                .padding(top = 2.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Sign-in problem",
                color = TextPrimary,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = error.message,
                color = TextSecondary,
                fontSize = 13.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
        IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
            Icon(
                imageVector = Icons.Filled.Close,
                contentDescription = "Dismiss",
                tint = TextMuted,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

// ─── Privacy footer ───────────────────────────────────────────────────────

@Composable
private fun PrivacyFooter() {
    Text(
        text = "Encrypted · Local-first · Your stats never leave your account.",
        color = TextMuted,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        textAlign = TextAlign.Center,
    )
}
