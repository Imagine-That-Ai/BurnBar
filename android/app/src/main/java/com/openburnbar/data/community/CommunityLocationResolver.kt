package com.openburnbar.data.community

import android.Manifest
import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.coroutines.resume

/** Fixed reverse-geocode locale so city labels match across platforms (e.g. "Milan" not "Milano"). */
private val GEOCODE_LOCALE: Locale = Locale.US

/**
 * Coarse OS location → canonical cityKey (`US-CA-san-francisco`).
 * Uses [Priority.PRIORITY_BALANCED_POWER_ACCURACY] (ACCESS_COARSE_LOCATION only).
 */
object CommunityLocationResolver {

    suspend fun resolveCoarseCityKey(context: Context): String? =
        withContext(Dispatchers.IO) {
            if (
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                ) != android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                return@withContext null
            }
            try {
                val fused = LocationServices.getFusedLocationProviderClient(context)
                val cancel = CancellationTokenSource()
                val location: Location? =
                    suspendCancellableCoroutine { cont ->
                        cont.invokeOnCancellation { cancel.cancel() }
                        fused
                            .getCurrentLocation(
                                Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                                cancel.token,
                            )
                            .addOnSuccessListener { loc -> cont.resume(loc) }
                            .addOnFailureListener { cont.resume(null) }
                    }
                val loc = location ?: return@withContext null

                if (!Geocoder.isPresent()) return@withContext null
                val geocoder = Geocoder(context, GEOCODE_LOCALE)
                val addresses =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        suspendCancellableCoroutine { cont ->
                            geocoder.getFromLocation(
                                loc.latitude,
                                loc.longitude,
                                1,
                            ) { list -> cont.resume(list) }
                        }
                    } else {
                        @Suppress("DEPRECATION")
                        geocoder.getFromLocation(loc.latitude, loc.longitude, 1)
                    }
                val address = addresses?.firstOrNull() ?: return@withContext null
                canonicalCityKeyFromAddress(address)
            } catch (_: SecurityException) {
                null
            }
        }

    internal fun canonicalCityKeyFromAddress(address: Address): String? {
        val cityName =
            address.locality?.trim()?.takeIf { it.isNotEmpty() }
                ?: address.subAdminArea?.trim()?.takeIf { it.isNotEmpty() }
                ?: address.adminArea?.trim()?.takeIf { it.isNotEmpty() }
                ?: return null
        val countryCode =
            address.countryCode?.trim()?.uppercase(Locale.ROOT)?.takeIf { it.isNotEmpty() }
                ?: return null
        val regionCode = normalizeRegionCode(address, countryCode) ?: return null
        val slug = CommunityCityKey.slugifyCity(cityName)
        if (slug.isEmpty()) return null
        return CommunityCityKey.canonicalizeCityKey(cityName, countryCode, regionCode)
    }

    /** ISO 3166-2 subdivision without country prefix (e.g. "CA", not "US-CA"). */
    internal fun normalizeRegionCode(address: Address, countryCode: String): String? {
        val admin =
            address.adminArea?.trim()?.takeIf { it.isNotEmpty() }
                ?: address.subAdminArea?.trim()?.takeIf { it.isNotEmpty() }
        if (admin == null) return countryCode
        val upper = admin.uppercase(Locale.ROOT)
        if (upper.length in 2..3 && upper.all { it.isLetterOrDigit() }) {
            return upper
        }
        val slug = CommunityCityKey.slugifyCity(admin)
        return slug.takeIf { it.isNotEmpty() }?.uppercase(Locale.ROOT) ?: countryCode
    }
}