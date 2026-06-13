package com.openburnbar.data.remoteconfig

import com.google.firebase.remoteconfig.FirebaseRemoteConfig

object RemoteConfigHardKillSwitches {
    const val MEDIA_KILL_SWITCH = "media_kill_switch"
    const val COMPUTER_USE_KILL_SWITCH = "computer_use_kill_switch"

    fun isActive(key: String): Boolean {
        val value = FirebaseRemoteConfig.getInstance().getValue(key)
        return value.source != FirebaseRemoteConfig.VALUE_SOURCE_REMOTE || value.asBoolean()
    }
}
