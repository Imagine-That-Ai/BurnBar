package com.openburnbar.data.community

import android.Manifest
import android.content.Context
import android.location.Address
import android.location.Geocoder
import android.location.Geocoder.GeocodeListener
import android.location.Location
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** Fixed reverse-geocode locale so city labels match across platforms (e.g. "Milan" not "Milano"). */
private val GEOCODE_LOCALE: Locale = Locale.US

/**
 * Coarse OS location → canonical cityKey (`US-CA-san-francisco`).
 * Uses [Priority.PRIORITY_BALANCED_POWER_ACCURACY] (ACCESS_COARSE_LOCATION only).
 */
object CommunityLocationResolver {

    private val REGION_NAME_TO_ISO: Map<String, Map<String, String>> =
        mapOf(
            "US" to
                mapOf(
                    "ALABAMA" to "AL",
                    "ALASKA" to "AK",
                    "ARIZONA" to "AZ",
                    "ARKANSAS" to "AR",
                    "CALIFORNIA" to "CA",
                    "COLORADO" to "CO",
                    "CONNECTICUT" to "CT",
                    "DELAWARE" to "DE",
                    "FLORIDA" to "FL",
                    "GEORGIA" to "GA",
                    "HAWAII" to "HI",
                    "IDAHO" to "ID",
                    "ILLINOIS" to "IL",
                    "INDIANA" to "IN",
                    "IOWA" to "IA",
                    "KANSAS" to "KS",
                    "KENTUCKY" to "KY",
                    "LOUISIANA" to "LA",
                    "MAINE" to "ME",
                    "MARYLAND" to "MD",
                    "MASSACHUSETTS" to "MA",
                    "MICHIGAN" to "MI",
                    "MINNESOTA" to "MN",
                    "MISSISSIPPI" to "MS",
                    "MISSOURI" to "MO",
                    "MONTANA" to "MT",
                    "NEBRASKA" to "NE",
                    "NEVADA" to "NV",
                    "NEW HAMPSHIRE" to "NH",
                    "NEW JERSEY" to "NJ",
                    "NEW MEXICO" to "NM",
                    "NEW YORK" to "NY",
                    "NORTH CAROLINA" to "NC",
                    "NORTH DAKOTA" to "ND",
                    "OHIO" to "OH",
                    "OKLAHOMA" to "OK",
                    "OREGON" to "OR",
                    "PENNSYLVANIA" to "PA",
                    "RHODE ISLAND" to "RI",
                    "SOUTH CAROLINA" to "SC",
                    "SOUTH DAKOTA" to "SD",
                    "TENNESSEE" to "TN",
                    "TEXAS" to "TX",
                    "UTAH" to "UT",
                    "VERMONT" to "VT",
                    "VIRGINIA" to "VA",
                    "WASHINGTON" to "WA",
                    "WEST VIRGINIA" to "WV",
                    "WISCONSIN" to "WI",
                    "WYOMING" to "WY",
                    "DISTRICT OF COLUMBIA" to "DC",
                ),
            "CA" to
                mapOf(
                    "ALBERTA" to "AB",
                    "BRITISH COLUMBIA" to "BC",
                    "MANITOBA" to "MB",
                    "NEW BRUNSWICK" to "NB",
                    "NEWFOUNDLAND AND LABRADOR" to "NL",
                    "NOVA SCOTIA" to "NS",
                    "ONTARIO" to "ON",
                    "PRINCE EDWARD ISLAND" to "PE",
                    "QUEBEC" to "QC",
                    "QUÉBEC" to "QC",
                    "SASKATCHEWAN" to "SK",
                    "NORTHWEST TERRITORIES" to "NT",
                    "NUNAVUT" to "NU",
                    "YUKON" to "YT",
                ),
            "AU" to
                mapOf(
                    "NEW SOUTH WALES" to "NSW",
                    "QUEENSLAND" to "QLD",
                    "SOUTH AUSTRALIA" to "SA",
                    "TASMANIA" to "TAS",
                    "VICTORIA" to "VIC",
                    "WESTERN AUSTRALIA" to "WA",
                    "AUSTRALIAN CAPITAL TERRITORY" to "ACT",
                    "NORTHERN TERRITORY" to "NT",
                ),
        )

    suspend fun resolveCoarseCityKey(context: Context): String? = withContext(Dispatchers.IO) {
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
                            object : GeocodeListener {
                                override fun onGeocode(addresses: MutableList<Address>) {
                                    if (cont.isActive) cont.resume(addresses)
                                }

                                override fun onError(errorMessage: String?) {
                                    if (cont.isActive) cont.resume(null)
                                }
                            },
                        )
                    }
                } else {
                    @Suppress("DEPRECATION") // reason: Android 12 and older require the synchronous Geocoder API.
                    geocoder.getFromLocation(loc.latitude, loc.longitude, 1)
                }
            val address = addresses?.firstOrNull() ?: return@withContext null
            canonicalCityKeyFromAddress(address)
        } catch (_: SecurityException) {
            null
        }
    }

    internal fun canonicalCityKeyFromAddress(address: Address): String? = canonicalCityKeyFromComponents(
        cityName = address.locality,
        subLocality = address.subLocality,
        countryCode = address.countryCode,
        adminArea = address.adminArea,
        subAdminArea = address.subAdminArea,
    )

    internal fun canonicalCityKeyFromComponents(
        cityName: String?,
        subLocality: String?,
        countryCode: String?,
        adminArea: String?,
        subAdminArea: String?,
    ): String? {
        val normalizedCity =
            cityName?.trim()?.takeIf { it.isNotEmpty() }
                ?: subLocality?.trim()?.takeIf { it.isNotEmpty() }
                ?: return null
        val normalizedCountry =
            countryCode?.trim()?.uppercase(Locale.ROOT)?.takeIf { it.isNotEmpty() }
                ?: return null
        val regionCode = normalizeRegionCode(adminArea, subAdminArea, normalizedCountry) ?: return null
        val slug = CommunityCityKey.slugifyCity(normalizedCity)
        if (slug.isEmpty()) return null
        return CommunityCityKey.canonicalizeCityKey(normalizedCity, normalizedCountry, regionCode)
    }

    /** ISO 3166-2 subdivision without country prefix (e.g. "CA", not "US-CA"). */
    internal fun normalizeRegionCode(address: Address, countryCode: String): String? = normalizeRegionCode(
        address.adminArea,
        address.subAdminArea,
        countryCode,
    )

    internal fun normalizeRegionCode(adminArea: String?, subAdminArea: String?, countryCode: String): String? {
        val admin =
            adminArea?.trim()?.takeIf { it.isNotEmpty() }
                ?: subAdminArea?.trim()?.takeIf { it.isNotEmpty() }
                ?: return null
        var upper = admin.uppercase(Locale.ROOT)
        if (upper.startsWith("$countryCode-")) {
            upper = upper.substring(countryCode.length + 1)
        }
        if (upper.length in 2..3 && upper.all { it.isLetterOrDigit() }) {
            return upper
        }
        REGION_NAME_TO_ISO[countryCode]?.get(upper)?.let { return it }
        val asciiName = CommunityCityKey.asciiFold(admin).uppercase(Locale.ROOT)
        REGION_NAME_TO_ISO[countryCode]?.get(asciiName)?.let { return it }
        return null
    }
}
