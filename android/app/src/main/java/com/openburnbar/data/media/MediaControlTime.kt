package com.openburnbar.data.media

private const val SWIFT_REFERENCE_DATE_UNIX_SECONDS = 978_307_200.0

internal fun mediaControlSwiftReferenceDateSecondsNow(): Double = System.currentTimeMillis() / 1_000.0 - SWIFT_REFERENCE_DATE_UNIX_SECONDS
