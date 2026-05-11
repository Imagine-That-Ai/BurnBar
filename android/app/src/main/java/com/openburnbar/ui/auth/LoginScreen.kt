package com.openburnbar.ui.auth

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.AuthError
import com.openburnbar.data.stores.UserStore

private val Ember = Color(0xFFFF6B35)
private val Charcoal = Color(0xFF1A1A2E)
private val DeepBlue = Color(0xFF16213E)
private val DarkBg = Color(0xFF0D0D0D)
private val LightBg = Color(0xFFF4F5F7)
private val LightCard = Color.White
private val DarkCard = Color(0xFF1E1E22)
private val SubtleDark = Color(0xFF9A9A9A)
private val SubtleLight = Color(0xFF6B6B6B)

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
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var showPw by remember { mutableStateOf(false) }
    var signUp by remember { mutableStateOf(false) }

    val googleLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { r -> if (r.resultCode == Activity.RESULT_OK) userStore.handleGoogleSignInResult(r.data) }

    val bg = if (isDark) Brush.verticalGradient(listOf(DarkBg, Charcoal, DeepBlue))
             else Brush.verticalGradient(listOf(LightBg, Color(0xFFE8ECEF), Color(0xFFDDE2E8)))
    val card = if (isDark) DarkCard else LightCard
    val sub = if (isDark) SubtleDark else SubtleLight
    val onBg = if (isDark) Color.White else Charcoal

    Box(Modifier.fillMaxSize().background(bg).clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { focus.clearFocus() }, contentAlignment = Alignment.Center) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 28.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            // Brand
            Text("🔥", fontSize = 48.sp)
            Spacer(Modifier.height(6.dp))
            Text("BurnBar", fontSize = 34.sp, fontWeight = FontWeight.Bold, color = onBg)
            Text("Track your agent spend", fontSize = 14.sp, color = sub)
            Spacer(Modifier.height(36.dp))

            // Error
            AnimatedVisibility(authError != null, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                if (authError != null) {
                    Surface(Modifier.fillMaxWidth().padding(bottom = 14.dp), RoundedCornerShape(10.dp), color = Color(0x22FF453A)) {
                        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(authError.message, color = Color(0xFFFF453A), fontSize = 13.sp, modifier = Modifier.weight(1f))
                            IconButton(onClick = onDismissError, modifier = Modifier.size(20.dp)) { Text("✕", color = Color(0xFFFF453A), fontSize = 12.sp) }
                        }
                    }
                }
            }

            // Card
            Surface(Modifier.fillMaxWidth(), RoundedCornerShape(22.dp), color = card, shadowElevation = 12.dp) {
                Column(Modifier.padding(22.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(if (signUp) "Create Account" else "Sign In", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = onBg)
                    Spacer(Modifier.height(22.dp))

                    SocialButton("Continue with Google", "G", Color.White, !isSigningIn, Modifier.fillMaxWidth()) {
                        googleLauncher.launch(userStore.getGoogleSignInIntent(context))
                    }
                    Spacer(Modifier.height(10.dp))
                    SocialButton("Continue with Apple", "🍎", Color.Black, !isSigningIn, Modifier.fillMaxWidth()) {
                        userStore.signInWithApple(context as Activity)
                    }

                    Spacer(Modifier.height(18.dp))
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        HorizontalDivider(Modifier.weight(1f))
                        Text("  or  ", fontSize = 12.sp, color = sub)
                        HorizontalDivider(Modifier.weight(1f))
                    }
                    Spacer(Modifier.height(18.dp))

                    OutlinedTextField(email, { email = it }, label = { Text("Email") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next, keyboardType = KeyboardType.Email),
                        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp))
                    Spacer(Modifier.height(10.dp))

                    OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true,
                        visualTransformation = if (showPw) VisualTransformation.None else PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done, keyboardType = KeyboardType.Password),
                        keyboardActions = KeyboardActions(onDone = {
                            focus.clearFocus()
                            if (signUp) userStore.signUpWithEmail(email, password) else userStore.signInWithEmail(email, password)
                        }),
                        trailingIcon = { IconButton({ showPw = !showPw }) { Icon(if (showPw) Icons.Default.VisibilityOff else Icons.Default.Visibility, "toggle") } },
                        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp))

                    Spacer(Modifier.height(18.dp))

                    Button({
                        focus.clearFocus()
                        if (signUp) userStore.signUpWithEmail(email, password) else userStore.signInWithEmail(email, password)
                    }, enabled = !isSigningIn && email.isNotBlank() && password.length >= 6,
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                        shape = RoundedCornerShape(12.dp), colors = ButtonDefaults.buttonColors(containerColor = Ember)) {
                        if (isSigningIn) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White)
                        else Text(if (signUp) "Sign Up" else "Sign In", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    }

                    Spacer(Modifier.height(12.dp))
                    Text(
                        if (signUp) "Already have an account? Sign In" else "Don't have an account? Sign Up",
                        fontSize = 13.sp, color = Ember, fontWeight = FontWeight.Medium,
                        modifier = Modifier.clickable { signUp = !signUp; onDismissError() })
                }
            }
        }
    }
}

@Composable
private fun SocialButton(text: String, icon: String, iconBg: Color, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    OutlinedButton(onClick, enabled = enabled, modifier = modifier.height(46.dp), shape = RoundedCornerShape(12.dp)) {
        Box(Modifier.size(26.dp).clip(RoundedCornerShape(6.dp)).background(iconBg), contentAlignment = Alignment.Center) {
            Text(icon, textAlign = TextAlign.Center, fontSize = 14.sp)
        }
        Spacer(Modifier.width(10.dp))
        Text(text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}
