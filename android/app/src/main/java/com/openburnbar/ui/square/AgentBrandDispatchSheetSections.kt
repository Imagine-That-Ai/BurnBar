@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.square

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.square.AgentIdentity

@Composable
internal fun DispatchSheetBody(identity: AgentIdentity, form: DispatchSheetFormState, callbacks: DispatchSheetCallbacks) {
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 18.dp)) {
        Text(
            "Dispatch to ${identity.displayName}",
            fontSize = 18.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(modifier = Modifier.height(12.dp))
        OutlinedTextField(
            value = form.title,
            onValueChange = callbacks.onTitleChange,
            placeholder = { Text("Title (optional)") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(modifier = Modifier.height(8.dp))
        OutlinedTextField(
            value = form.prompt,
            onValueChange = callbacks.onPromptChange,
            placeholder = { Text("What should ${identity.displayName} do?") },
            modifier = Modifier.fillMaxWidth().height(120.dp),
        )
        Spacer(modifier = Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Switch(checked = form.commandsAllowed, onCheckedChange = callbacks.onCommandsAllowedChange)
            Spacer(modifier = Modifier.width(8.dp))
            Text("Allow shell commands", fontSize = 12.sp)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Switch(checked = form.fileEditsAllowed, onCheckedChange = callbacks.onFileEditsAllowedChange)
            Spacer(modifier = Modifier.width(8.dp))
            Text("Allow file edits", fontSize = 12.sp)
        }
        form.inlineError?.let { msg ->
            Spacer(modifier = Modifier.height(8.dp))
            Text(msg, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
        }
        Spacer(modifier = Modifier.height(14.dp))
        Button(
            onClick = callbacks.onDispatch,
            enabled = !form.dispatching && form.prompt.trim().isNotBlank(),
            modifier = Modifier.fillMaxWidth(),
        ) {
            if (form.dispatching) {
                CircularProgressIndicator(
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(16.dp),
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            } else {
                Text("Dispatch")
            }
        }
    }
}
