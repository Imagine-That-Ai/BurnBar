package com.openburnbar.data.recap

object RecapConstants {
    const val MILLIS_PER_SECOND = 1000L
    const val SECONDS_PER_MINUTE = 60
    const val MINUTES_PER_HOUR = 60
    const val SECONDS_PER_HOUR = 3600
    const val HOURS_PER_DAY = 24
    const val DAYS_PER_WEEK = 7
    const val MILLIS_PER_MINUTE = 60_000L
    const val MILLIS_PER_HOUR = 3_600_000L
    const val MILLIS_PER_DAY = 86_400_000L

    const val PERCENT_100 = 100.0
    const val HASH_INIT = 5381L
    const val HASH_SHIFT = 5

    // Fleet rule thresholds
    const val MIN_FLEET_COMBINATIONS = 4
    const val TOP_THREE_MIN_SHARE = 0.5
    const val NEW_MODEL_MIN_TOKENS = 500L
    const val MOVER_SHARE_DELTA = 0.15
    const val DECLINE_PRIOR_MIN_SHARE = 0.2
    const val PAIRING_MIN_SHARE = 0.25
    const val TOP_SHARE_NOVELTY = 0.95

    // Economy rule thresholds
    const val MIN_SPEND_THRESHOLD = 0.01
    const val SPEND_SHIFT_MIN_DELTA = 0.15
    const val MIN_MONTHS_FOR_RECORD = 3
    const val RECORD_MARGIN_MIN = 0.1
    const val CACHE_HIT_MIN_RATE = 0.2
    const val CACHE_DELTA_THRESHOLD = 0.05
    const val SESSION_COUNT_THRESHOLD = 5
    const val COST_PER_SESSION_DELTA = 0.25
    const val THINKING_SHARE_MIN = 0.08

    // Rhythm rule thresholds
    const val PEAK_WEEKDAY_MIN_SHARE = 0.25
    const val LATE_NIGHT_MIN_SHARE = 0.15
    const val PEAK_HOUR_MIN_SHARE = 0.12
    const val WEEKEND_HIGH_SHARE = 0.3
    const val WEEKEND_LOW_SHARE = 0.04
    const val WEEKEND_MIN_ACTIVE_DAYS = 8
    const val MIN_STREAK_DAYS = 3
    const val BUSIEST_DAY_MULTIPLE = 1.8
    const val LONGEST_SESSION_MIN_SECONDS = 1200.0 // 20 minutes
    const val SESSION_LENGTH_DELTA = 0.2
    const val SHOW_UP_MIN_DAYS = 5
    const val SHOW_UP_MIN_RATE = 0.3

    // Substance criteria
    const val MIN_SUBSTANCE_COST = 0.25
    const val MIN_SUBSTANCE_TOKENS = 1000L
    const val MIN_SUBSTANCE_SESSIONS = 2
}
