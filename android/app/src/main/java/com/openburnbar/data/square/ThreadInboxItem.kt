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
    val searchText: String = listOf(title, preview, agentURI).joinToString(" "),
    val customTitle: String? = null,
    val labelColorHex: String? = null,
    val isPinned: Boolean = false,
    val priorityOrder: Int? = null
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
    sortedWith(Comparator { a, b ->
        // 1. Pinned first
        if (a.isPinned != b.isPinned) {
            return@Comparator if (a.isPinned) -1 else 1
        }
        // 2. Needs attention second
        if (a.needsAttention != b.needsAttention) {
            return@Comparator if (a.needsAttention) -1 else 1
        }
        // 3. priorityOrder ascending (where smaller assigned values rank higher than unassigned null/0)
        val pA = a.priorityOrder?.takeIf { it > 0 }
        val pB = b.priorityOrder?.takeIf { it > 0 }
        if (pA != pB) {
            if (pA != null && pB != null) {
                return@Comparator pA.compareTo(pB)
            } else if (pA != null) {
                return@Comparator -1
            } else if (pB != null) {
                return@Comparator 1
            }
        }
        // 4. lastActivityAtEpoch recency descending
        return@Comparator b.lastActivityAtEpoch.compareTo(a.lastActivityAtEpoch)
    })

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
