// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.you

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.openburnbar.data.stores.DeviceRecord
import com.openburnbar.data.stores.DeviceTrustState
import com.openburnbar.data.stores.DevicesStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.WebsiteBackground
import com.openburnbar.ui.settings.rememberWebsiteBackground
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

@Composable
fun ConnectedDevicesScreen(store: DevicesStore, onBack: () -> Unit) {
    val context = LocalContext.current
    val devices by store.devices.collectAsStateWithLifecycle()
    val isLoading by store.isLoading.collectAsStateWithLifecycle()
    val lastError by store.lastError.collectAsStateWithLifecycle()
    val actionInFlightFor by store.actionInFlightFor.collectAsStateWithLifecycle()

    LaunchedEffect(store, context) {
        store.initialize(context)
        store.load()
    }

    ConnectedDevicesContent(
        devices = devices,
        isLoading = isLoading,
        lastError = lastError,
        actionInFlightFor = actionInFlightFor,
        bootstrapEligible = store.bootstrapEligible,
        staleDuplicateCount = store.staleDuplicates.size,
        onBack = onBack,
        onRefresh = store::load,
        onBootstrapApproveSelf = store::bootstrapApproveSelf,
        onRenameSelf = store::renameSelf,
        onApprove = store::approve,
        onRevoke = store::revoke,
        onCleanupDuplicates = store::revokeStaleDuplicates,
    )
}

@Composable
internal fun ConnectedDevicesContent(
    devices: List<DeviceRecord>,
    isLoading: Boolean,
    lastError: String?,
    actionInFlightFor: String?,
    bootstrapEligible: Boolean,
    staleDuplicateCount: Int,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onBootstrapApproveSelf: () -> Unit,
    onRenameSelf: (String) -> Unit,
    onApprove: (DeviceRecord) -> Unit,
    onRevoke: (DeviceRecord) -> Unit,
    onCleanupDuplicates: () -> Unit,
) {
    var renameDevice by remember { mutableStateOf<DeviceRecord?>(null) }
    var approveDevice by remember { mutableStateOf<DeviceRecord?>(null) }
    var revokeDevice by remember { mutableStateOf<DeviceRecord?>(null) }
    var confirmCleanup by rememberSaveable { mutableStateOf(false) }

    ConnectedDevicesBody(
        devices = devices,
        isLoading = isLoading,
        lastError = lastError,
        actionInFlightFor = actionInFlightFor,
        bootstrapEligible = bootstrapEligible,
        staleDuplicateCount = staleDuplicateCount,
        onBack = onBack,
        onRefresh = onRefresh,
        onBootstrapApproveSelf = onBootstrapApproveSelf,
        onRenameDevice = { renameDevice = it },
        onApproveDevice = { approveDevice = it },
        onRevokeDevice = { revokeDevice = it },
        onCleanupRequest = { confirmCleanup = true },
    )

    ConnectedDevicesDialogs(
        renameDevice = renameDevice,
        approveDevice = approveDevice,
        revokeDevice = revokeDevice,
        confirmCleanup = confirmCleanup,
        staleDuplicateCount = staleDuplicateCount,
        onRenameSelf = onRenameSelf,
        onApprove = onApprove,
        onRevoke = onRevoke,
        onCleanupDuplicates = onCleanupDuplicates,
        onClearRename = { renameDevice = null },
        onClearApprove = { approveDevice = null },
        onClearRevoke = { revokeDevice = null },
        onClearCleanup = { confirmCleanup = false },
    )
}

@Composable
private fun ConnectedDevicesBody(
    devices: List<DeviceRecord>,
    isLoading: Boolean,
    lastError: String?,
    actionInFlightFor: String?,
    bootstrapEligible: Boolean,
    staleDuplicateCount: Int,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onBootstrapApproveSelf: () -> Unit,
    onRenameDevice: (DeviceRecord) -> Unit,
    onApproveDevice: (DeviceRecord) -> Unit,
    onRevokeDevice: (DeviceRecord) -> Unit,
    onCleanupRequest: () -> Unit,
) {
    ConnectedDevicesBackground {
        LazyColumn(
            modifier =
            Modifier
                .fillMaxSize()
                .padding(horizontal = AuroraSpacing.LG.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp),
        ) {
            connectedDevicesItems(
                devices = devices,
                isLoading = isLoading,
                lastError = lastError,
                actionInFlightFor = actionInFlightFor,
                bootstrapEligible = bootstrapEligible,
                staleDuplicateCount = staleDuplicateCount,
                onBack = onBack,
                onRefresh = onRefresh,
                onBootstrapApproveSelf = onBootstrapApproveSelf,
                onRenameDevice = onRenameDevice,
                onApproveDevice = onApproveDevice,
                onRevokeDevice = onRevokeDevice,
                onCleanupRequest = onCleanupRequest,
            )
        }
    }
}

private fun LazyListScope.connectedDevicesItems(
    devices: List<DeviceRecord>,
    isLoading: Boolean,
    lastError: String?,
    actionInFlightFor: String?,
    bootstrapEligible: Boolean,
    staleDuplicateCount: Int,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onBootstrapApproveSelf: () -> Unit,
    onRenameDevice: (DeviceRecord) -> Unit,
    onApproveDevice: (DeviceRecord) -> Unit,
    onRevokeDevice: (DeviceRecord) -> Unit,
    onCleanupRequest: () -> Unit,
) {
    item {
        Spacer(Modifier.height(AuroraSpacing.LG.dp))
        ConnectedDevicesTopBar(isLoading = isLoading, onBack = onBack, onRefresh = onRefresh)
    }
    if (lastError != null) {
        item { ConnectedDevicesErrorCard(lastError) }
    }
    item {
        ThisDeviceSection(
            currentDevice = devices.firstOrNull { it.isCurrentDevice },
            isLoading = isLoading,
            actionInFlightFor = actionInFlightFor,
            bootstrapEligible = bootstrapEligible,
            onBootstrapApproveSelf = onBootstrapApproveSelf,
            onRenameDevice = onRenameDevice,
        )
    }
    item {
        OtherDevicesSection(
            otherDevices = devices.filterNot { it.isCurrentDevice },
            actionInFlightFor = actionInFlightFor,
            onApproveDevice = onApproveDevice,
            onRevokeDevice = onRevokeDevice,
        )
    }
    if (staleDuplicateCount > 0) {
        item {
            CleanupSection(
                staleDuplicateCount = staleDuplicateCount,
                actionsEnabled = actionInFlightFor == null,
                onCleanupRequest = onCleanupRequest,
            )
        }
    }
    item { Spacer(Modifier.height(AuroraSpacing.XXXL.dp)) }
}

@Composable
private fun ConnectedDevicesBackground(content: @Composable () -> Unit) {
    val isDark = isSystemInDarkTheme()
    val useWebsiteBackground by rememberWebsiteBackground()
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                when {
                    useWebsiteBackground -> Color.Transparent
                    isDark -> AuroraColors.darkBackground
                    else -> AuroraColors.lightBackground
                },
            )
            .testTag("connectedDevices.screen"),
    ) {
        if (useWebsiteBackground) {
            WebsiteBackground(accentColor = AuroraColors.hermesMercury)
        }
        content()
    }
}

@Composable
private fun ConnectedDevicesErrorCard(lastError: String) {
    AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
        Text(
            text = lastError,
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun ThisDeviceSection(
    currentDevice: DeviceRecord?,
    isLoading: Boolean,
    actionInFlightFor: String?,
    bootstrapEligible: Boolean,
    onBootstrapApproveSelf: () -> Unit,
    onRenameDevice: (DeviceRecord) -> Unit,
) {
    DeviceSection(title = "This device") {
        if (currentDevice == null) {
            EmptyDeviceMessage(
                if (isLoading) "Loading this device…" else "This installation is not registered yet.",
            )
        } else {
            DeviceRow(
                device = currentDevice,
                actionInFlight = actionInFlightFor == currentDevice.stableIdentity,
                onApprove = null,
                onRevoke = null,
                onRename = { onRenameDevice(currentDevice) },
            )
            if (bootstrapEligible) {
                HorizontalDivider()
                Button(
                    onClick = onBootstrapApproveSelf,
                    enabled = actionInFlightFor == null,
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .testTag("connectedDevices.approveThisDevice"),
                ) {
                    Icon(Icons.Filled.Shield, contentDescription = null)
                    Text("Approve this device", modifier = Modifier.padding(start = 8.dp))
                }
            }
        }
    }
}

@Composable
private fun OtherDevicesSection(
    otherDevices: List<DeviceRecord>,
    actionInFlightFor: String?,
    onApproveDevice: (DeviceRecord) -> Unit,
    onRevokeDevice: (DeviceRecord) -> Unit,
) {
    DeviceSection(title = "Other devices") {
        if (otherDevices.isEmpty()) {
            EmptyDeviceMessage("No other devices are connected.")
        } else {
            otherDevices.forEachIndexed { index, device ->
                if (index > 0) HorizontalDivider()
                DeviceRow(
                    device = device,
                    actionInFlight = actionInFlightFor == device.stableIdentity,
                    onApprove =
                    if (device.trustState == DeviceTrustState.PENDING) {
                        { onApproveDevice(device) }
                    } else {
                        null
                    },
                    onRevoke =
                    if (device.trustState == DeviceTrustState.TRUSTED) {
                        { onRevokeDevice(device) }
                    } else {
                        null
                    },
                    onRename = null,
                )
            }
        }
    }
}

@Composable
private fun CleanupSection(staleDuplicateCount: Int, actionsEnabled: Boolean, onCleanupRequest: () -> Unit) {
    DeviceSection(title = "Cleanup") {
        Text(
            "$staleDuplicateCount older device ${if (staleDuplicateCount == 1) "copy is" else "copies are"} hidden from the main list.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodyMedium,
        )
        OutlinedButton(
            onClick = onCleanupRequest,
            enabled = actionsEnabled,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Remove duplicate copies")
        }
    }
}

@Composable
private fun ConnectedDevicesDialogs(
    renameDevice: DeviceRecord?,
    approveDevice: DeviceRecord?,
    revokeDevice: DeviceRecord?,
    confirmCleanup: Boolean,
    staleDuplicateCount: Int,
    onRenameSelf: (String) -> Unit,
    onApprove: (DeviceRecord) -> Unit,
    onRevoke: (DeviceRecord) -> Unit,
    onCleanupDuplicates: () -> Unit,
    onClearRename: () -> Unit,
    onClearApprove: () -> Unit,
    onClearRevoke: () -> Unit,
    onClearCleanup: () -> Unit,
) {
    renameDevice?.let { device ->
        RenameDeviceDialog(
            device = device,
            onDismiss = onClearRename,
            onConfirm = { name ->
                onClearRename()
                onRenameSelf(name)
            },
        )
    }
    approveDevice?.let { device ->
        ApproveDeviceDialog(
            device = device,
            onDismiss = onClearApprove,
            onConfirm = {
                onClearApprove()
                onApprove(device)
            },
        )
    }
    revokeDevice?.let { device ->
        RevokeDeviceDialog(
            device = device,
            onDismiss = onClearRevoke,
            onConfirm = {
                onClearRevoke()
                onRevoke(device)
            },
        )
    }
    if (confirmCleanup) {
        CleanupConfirmDialog(
            staleDuplicateCount = staleDuplicateCount,
            onDismiss = onClearCleanup,
            onConfirm = {
                onClearCleanup()
                onCleanupDuplicates()
            },
        )
    }
}

@Composable
private fun RevokeDeviceDialog(device: DeviceRecord, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Revoke ${device.displayName}?") },
        text = { Text("This device will immediately lose access to your OpenBurnBar data.") },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) {
                Text("Revoke")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun CleanupConfirmDialog(staleDuplicateCount: Int, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Remove duplicate copies?") },
        text = { Text("Only older duplicate registrations will be revoked. Active devices stay connected.") },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
            ) {
                Text("Remove $staleDuplicateCount")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun ConnectedDevicesTopBar(isLoading: Boolean, onBack: () -> Unit, onRefresh: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onBack) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
        }
        Column(modifier = Modifier.weight(1f)) {
            Text("Connected Devices", style = AuroraType.displayLarge)
            Text(
                "Review approvals and remove access you no longer trust.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        IconButton(
            onClick = onRefresh,
            enabled = !isLoading,
            modifier = Modifier.testTag("connectedDevices.refresh"),
        ) {
            if (isLoading) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh connected devices")
            }
        }
    }
}

@Composable
private fun DeviceSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        AuroraGlassCard(
            modifier = Modifier.fillMaxWidth(),
            content = content,
        )
    }
}

@Composable
private fun DeviceRow(device: DeviceRecord, actionInFlight: Boolean, onApprove: (() -> Unit)?, onRevoke: (() -> Unit)?, onRename: (() -> Unit)?) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .testTag("connectedDevices.device.${device.id}"),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp),
    ) {
        DeviceRowHeader(device)
        if (device.trustState == DeviceTrustState.PENDING) {
            DeviceRowSafetyCode(device)
        }
        DeviceRowActions(
            device = device,
            actionInFlight = actionInFlight,
            onApprove = onApprove,
            onRevoke = onRevoke,
            onRename = onRename,
        )
    }
}

@Composable
private fun DeviceRowHeader(device: DeviceRecord) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            imageVector = if (device.trustState == DeviceTrustState.TRUSTED) Icons.Filled.CheckCircle else Icons.Filled.Devices,
            contentDescription = null,
            tint = trustColor(device.trustState),
        )
        Column(
            modifier =
            Modifier
                .weight(1f)
                .padding(start = AuroraSpacing.MD.dp),
        ) {
            Text(device.displayName.ifBlank { "Unnamed device" }, fontWeight = FontWeight.SemiBold)
            Text(
                "${device.platform.ifBlank { "Unknown platform" }} · ${device.id.take(12)}",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
            )
        }
        Text(
            trustLabel(device.trustState),
            color = trustColor(device.trustState),
            style = MaterialTheme.typography.labelMedium,
        )
    }
}

@Composable
private fun DeviceRowSafetyCode(device: DeviceRecord) {
    val safetyCode = device.safetyCode
    Text(
        safetyCode ?: "Waiting for this device to publish a verified safety code.",
        color =
        if (device.hasVerifiedSafetyCode) {
            MaterialTheme.colorScheme.onSurfaceVariant
        } else {
            MaterialTheme.colorScheme.error
        },
        style = MaterialTheme.typography.bodySmall,
        fontFamily = if (safetyCode != null) FontFamily.Monospace else FontFamily.Default,
    )
}

@Composable
private fun DeviceRowActions(device: DeviceRecord, actionInFlight: Boolean, onApprove: (() -> Unit)?, onRevoke: (() -> Unit)?, onRename: (() -> Unit)?) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (actionInFlight) {
            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
        } else {
            onRename?.let {
                TextButton(
                    onClick = it,
                    modifier = Modifier.testTag("connectedDevices.rename"),
                ) {
                    Text("Rename")
                }
            }
            onApprove?.let {
                Button(
                    onClick = it,
                    enabled = device.hasVerifiedSafetyCode,
                    modifier = Modifier.testTag("connectedDevices.approve.${device.id}"),
                ) {
                    Text("Approve")
                }
            }
            onRevoke?.let {
                OutlinedButton(
                    onClick = it,
                    modifier = Modifier.testTag("connectedDevices.revoke.${device.id}"),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
                ) {
                    Text("Revoke")
                }
            }
        }
    }
}

@Composable
private fun RenameDeviceDialog(device: DeviceRecord, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var name by rememberSaveable(device.id) { mutableStateOf(device.displayName) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename this device") },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Device name") },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name.trim()) },
                enabled = name.trim().isNotEmpty(),
            ) {
                Text("Save")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ApproveDeviceDialog(device: DeviceRecord, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    var compared by rememberSaveable(device.id) { mutableStateOf(false) }
    val safetyCode = device.safetyCode
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Verify ${device.displayName}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.MD.dp)) {
                Text("Compare this code with the one shown on the pending device. Approve only if they match exactly.")
                Text(
                    safetyCode ?: "No verified safety code is available.",
                    style = MaterialTheme.typography.titleMedium,
                    fontFamily = FontFamily.Monospace,
                    color =
                    if (device.hasVerifiedSafetyCode) {
                        MaterialTheme.colorScheme.onSurface
                    } else {
                        MaterialTheme.colorScheme.error
                    },
                )
                if (device.hasVerifiedSafetyCode) {
                    Row(
                        modifier =
                        Modifier
                            .fillMaxWidth()
                            .toggleable(
                                value = compared,
                                role = Role.Checkbox,
                                onValueChange = { compared = it },
                            )
                            .testTag("connectedDevices.approve.compared"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = compared, onCheckedChange = null)
                        Text("I compared both codes and they match.")
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                enabled = device.hasVerifiedSafetyCode && compared,
                modifier = Modifier.testTag("connectedDevices.approve.confirm"),
            ) {
                Text("Approve")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun EmptyDeviceMessage(message: String) {
    Text(
        message,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.bodyMedium,
    )
}

@Composable
private fun trustColor(state: DeviceTrustState): Color = when (state) {
    DeviceTrustState.TRUSTED -> AuroraColors.success
    DeviceTrustState.PENDING -> AuroraColors.warning
    DeviceTrustState.REVOKED -> MaterialTheme.colorScheme.error
}

private fun trustLabel(state: DeviceTrustState): String = when (state) {
    DeviceTrustState.TRUSTED -> "Trusted"
    DeviceTrustState.PENDING -> "Pending"
    DeviceTrustState.REVOKED -> "Revoked"
}
