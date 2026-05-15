package com.openburnbar.data.square

// MARK: - Thread Inbox Item (Android parity)

data class ThreadInboxItem(
    val id: String,
    val agentURI: String,
    val title: String,
    val preview: String,
    val lastActivityAtEpoch: Long,
    val unreadCount: Int = 0,
    val needsAttention: Boolean = false,
    val source: Source,
    val liveMissionID: String? = null,
    val searchText: String = listOf(title, preview, agentURI).joinToString(" ")
) {
    enum class Source(val token: String) {
        HERMES("hermes"),
        PI("pi"),
        CLI_MIRROR("cli_mirror"),
        MISSION_GROUP("mission_group"),
        SUBSCRIPTION_POST("subscription_post");

        companion object {
            fun fromToken(value: String?): Source =
                values().firstOrNull { it.token == value } ?: HERMES
        }
    }
}

fun List<ThreadInboxItem>.sortedForInbox(): List<ThreadInboxItem> =
    sortedWith(compareByDescending<ThreadInboxItem> { it.needsAttention }
        .thenByDescending { it.lastActivityAtEpoch })

fun List<ThreadInboxItem>.splitForInbox(): Pair<List<ThreadInboxItem>, List<ThreadInboxItem>> {
    val service = mutableListOf<ThreadInboxItem>()
    val subscription = mutableListOf<ThreadInboxItem>()
    for (item in this) {
        when (item.source) {
            ThreadInboxItem.Source.SUBSCRIPTION_POST -> subscription.add(item)
            else -> service.add(item)
        }
    }
    return service.sortedForInbox() to subscription.sortedForInbox()
}
