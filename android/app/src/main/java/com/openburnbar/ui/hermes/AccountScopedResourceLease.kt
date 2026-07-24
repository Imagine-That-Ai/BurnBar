package com.openburnbar.ui.hermes

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.hermes.HermesService

internal class AccountScopedResourceLease<T : Any>(
    val accountUid: String,
    val resource: T,
) {
    private var closed = false

    @Synchronized
    fun close(dispose: (T) -> Unit) {
        if (closed) return
        closed = true
        dispose(resource)
    }
}

private val LocalHermesAccountUid = compositionLocalOf<String?> { null }

@Composable
internal fun AccountScopedHermesServiceProvider(accountUid: String, content: @Composable () -> Unit) {
    val normalizedUid = accountUid.trim()
    require(normalizedUid.isNotEmpty()) { "An authenticated account is required for the signed-in shell." }
    CompositionLocalProvider(LocalHermesAccountUid provides normalizedUid, content = content)
}

@Composable
internal fun rememberAccountScopedHermesService(
    factory: (Context, String) -> HermesService = { context, _ -> HermesService(appContext = context) },
): HermesService {
    val appContext = LocalContext.current.applicationContext
    val create = remember(appContext, factory) {
        { uid: String -> factory(appContext, uid) }
    }
    val dispose = remember { { service: HermesService -> service.destroy() } }
    return rememberAccountScopedResource(create = create, dispose = dispose)
}

@Composable
internal fun <T : Any> rememberAccountScopedResource(create: (String) -> T, dispose: (T) -> Unit): T {
    val accountUid = requireNotNull(LocalHermesAccountUid.current) {
        "Account-scoped resources must be owned by AccountScopedHermesServiceProvider."
    }
    val normalizedUid = accountUid.trim().also {
        require(it.isNotEmpty()) { "An authenticated account is required for this resource." }
    }
    val lease = remember(normalizedUid, create) {
        AccountScopedResourceLease(
            accountUid = normalizedUid,
            resource = create(normalizedUid),
        )
    }
    DisposableEffect(lease, dispose) {
        onDispose { lease.close(dispose) }
    }
    return lease.resource
}
