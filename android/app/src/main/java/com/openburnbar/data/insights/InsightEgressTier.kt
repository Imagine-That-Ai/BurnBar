package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Describes where the data goes when a model is invoked.
 */
@Serializable
enum class InsightEgressTier(val displayLabel: String) {
    @SerialName("localOnly") LOCAL_ONLY("Stays on device"),
    @SerialName("userKey") USER_KEY("Your API key"),
    @SerialName("userRelay") USER_RELAY("Your relay"),
    @SerialName("hosted") HOSTED("OpenBurnBar hosted");
}
