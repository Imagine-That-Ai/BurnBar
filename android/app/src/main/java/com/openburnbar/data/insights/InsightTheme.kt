package com.openburnbar.data.insights

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Visual preset applied to an entire canvas.
 */
@Serializable
enum class InsightTheme {
    @SerialName("aurora") AURORA,
    @SerialName("ember") EMBER,
    @SerialName("mercury") MERCURY,
    @SerialName("whimsy") WHIMSY,
    @SerialName("mono") MONO,
    @SerialName("print") PRINT;
}
