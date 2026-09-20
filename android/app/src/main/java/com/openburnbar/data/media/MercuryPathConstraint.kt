package com.openburnbar.data.media

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

object MercuryPathConstraint {
    fun isConstrained(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return false
        val network = manager.activeNetwork ?: return false
        val capabilities = manager.getNetworkCapabilities(network) ?: return false
        val cellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
        val expensive = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        val constrained = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_CONGESTED)
        return MediaBweFeedbackPayload.isConstrainedPath(
            usesCellular = cellular,
            isExpensive = expensive,
            isConstrained = constrained,
        )
    }
}
