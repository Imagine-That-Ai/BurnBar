package com.openburnbar.data.square

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.openburnbar.data.hermes.HermesConnectionRecord

// MARK: - Agent Identity Registry (Android parity)
//
// Composable-state registry of every agent the user has access to.
// Seeds with the five built-ins on construction; future Phase C wires
// user-installed manifests.

class AgentIdentityRegistry private constructor() {
    var identities by mutableStateOf<List<AgentIdentity>>(AgentIdentity.defaultBuiltIns)
        private set

    var lastRefreshedAtEpoch by mutableStateOf<Long?>(null)
        private set

    fun identity(uri: String): AgentIdentity? =
        identities.firstOrNull { it.id == uri }
            ?: uri.takeIf { it.startsWith(AgentIdentity.PAIRED_MAC_URI_PREFIX) }
                ?.let(AgentIdentity::pairedMacPlaceholder)

    fun upsertPairedMac(connection: HermesConnectionRecord): AgentIdentity {
        val identity = AgentIdentity.pairedMac(connection)
        identities = if (identities.any { it.id == identity.id }) {
            identities.map { if (it.id == identity.id) identity else it }
        } else {
            identities + identity
        }
        lastRefreshedAtEpoch = System.currentTimeMillis()
        return identity
    }

    val builtIns: List<AgentIdentity>
        get() = identities.filter { it.installSource is AgentInstallSource.BuiltIn }

    val userInstalled: List<AgentIdentity>
        get() = identities.filter { it.installSource is AgentInstallSource.UserInstalled }

    fun refreshAvailability(map: Map<String, AgentAvailability>) {
        val now = System.currentTimeMillis()
        identities = identities.map { existing ->
            val newAvailability = map[existing.id] ?: existing.availability
            existing.copy(
                availability = newAvailability,
                lastRefreshedAtEpoch = now
            )
        }
        lastRefreshedAtEpoch = now
    }

    fun updatePersonas(uri: String, personas: List<AgentPersonaModel>) {
        identities = identities.map { existing ->
            if (existing.id != uri) existing
            else existing.copy(
                personas = personas,
                lastRefreshedAtEpoch = System.currentTimeMillis()
            )
        }
    }

    companion object {
        @Volatile
        private var instance: AgentIdentityRegistry? = null

        fun shared(): AgentIdentityRegistry =
            instance ?: synchronized(this) {
                instance ?: AgentIdentityRegistry().also { instance = it }
            }

        internal fun testInstance(): AgentIdentityRegistry = AgentIdentityRegistry()
    }
}
