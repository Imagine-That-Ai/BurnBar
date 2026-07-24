package com.openburnbar.data.computeruse

import android.app.Activity
import android.app.Application
import android.os.Bundle
import androidx.fragment.app.FragmentActivity
import java.lang.ref.WeakReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/** Supplies the resumed FragmentActivity required by the biometric challenge flow. */
object ForegroundFragmentActivityTracker {
    @Volatile private var currentActivity = WeakReference<FragmentActivity>(null)
    private val resumedActivity = MutableStateFlow<FragmentActivity?>(null)

    @Volatile private var installed = false

    fun install(application: Application) {
        if (installed) return
        installed = true
        application.registerActivityLifecycleCallbacks(
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityResumed(activity: Activity) {
                    if (activity is FragmentActivity) {
                        currentActivity = WeakReference(activity)
                        resumedActivity.value = activity
                    }
                }

                override fun onActivityPaused(activity: Activity) {
                    if (currentActivity.get() === activity) {
                        currentActivity.clear()
                        resumedActivity.compareAndSet(activity as? FragmentActivity, null)
                    }
                }

                override fun onActivityDestroyed(activity: Activity) {
                    if (currentActivity.get() === activity) {
                        currentActivity.clear()
                        resumedActivity.compareAndSet(activity as? FragmentActivity, null)
                    }
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
                override fun onActivityStarted(activity: Activity) = Unit
                override fun onActivityStopped(activity: Activity) = Unit
                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            },
        )
    }

    fun current(): FragmentActivity? = currentActivity.get()

    suspend fun awaitResumedUntil(expiresAtMillis: Long, nowMillis: () -> Long = { System.currentTimeMillis() }): FragmentActivity? {
        current()?.let { return it }
        val remainingMillis = expiresAtMillis - nowMillis()
        if (remainingMillis <= 0L) return null
        return withTimeoutOrNull(remainingMillis) { resumedActivity.filterNotNull().first() }
    }
}
