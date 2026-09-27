package com.openburnbar.ui.components

import androidx.compose.ui.graphics.Color
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Generated spline produce for cooking mode (apple/cherry/banana/cookie/cupcake). */
internal fun generateApplePoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val bodyCtrls =
        listOf(
            0.0 to -0.22,
            0.18 to -0.42,
            0.46 to -0.32,
            0.56 to -0.06,
            0.42 to 0.28,
            0.16 to 0.44,
            0.0 to 0.36,
            -0.16 to 0.44,
            -0.42 to 0.28,
            -0.56 to -0.06,
            -0.46 to -0.32,
            -0.18 to -0.42,
        )
    pts.addAll(generateSpline(bodyCtrls, 30, Color(0xFFFF2A6D), Color(0xFFFF5E3A), isClosed = true))

    val stemCtrls =
        listOf(
            0.0 to -0.25,
            0.02 to -0.38,
            0.08 to -0.50,
            0.15 to -0.58,
        )
    pts.addAll(generateSpline(stemCtrls, 15, Color(0xFF8E5A32), Color(0xFF5C4033), isClosed = false))

    val leafCtrls =
        listOf(
            0.06 to -0.46,
            0.18 to -0.58,
            0.32 to -0.58,
            0.18 to -0.42,
        )
    pts.addAll(generateSpline(leafCtrls, 20, Color(0xFF2ECC71), Color(0xFF7FFF00), isClosed = true))
    return pts
}

internal fun generateCherryPoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val leftCherryCtrls =
        listOf(
            -0.25 to 0.06,
            -0.13 to 0.12,
            -0.08 to 0.22,
            -0.14 to 0.32,
            -0.25 to 0.38,
            -0.36 to 0.32,
            -0.42 to 0.22,
            -0.36 to 0.12,
        )
    pts.addAll(generateSpline(leftCherryCtrls, 25, Color(0xFFFF1493), Color(0xFFFF2A6D), isClosed = true))

    val rightCherryCtrls =
        listOf(
            0.22 to 0.14,
            0.33 to 0.20,
            0.38 to 0.30,
            0.32 to 0.40,
            0.22 to 0.46,
            0.12 to 0.40,
            0.06 to 0.30,
            0.12 to 0.20,
        )
    pts.addAll(generateSpline(rightCherryCtrls, 25, Color(0xFFFF2A6D), Color(0xFF9B59B6), isClosed = true))

    val leftStemCtrls =
        listOf(
            0.0 to -0.32,
            -0.05 to -0.18,
            -0.15 to -0.05,
            -0.25 to 0.08,
        )
    pts.addAll(generateSpline(leftStemCtrls, 15, Color(0xFF2ECC71), Color(0xFF27AE60), isClosed = false))

    val rightStemCtrls =
        listOf(
            0.0 to -0.32,
            0.08 to -0.15,
            0.16 to 0.0,
            0.22 to 0.16,
        )
    pts.addAll(generateSpline(rightStemCtrls, 15, Color(0xFF2ECC71), Color(0xFF27AE60), isClosed = false))

    val leafCtrls =
        listOf(
            0.0 to -0.32,
            0.12 to -0.45,
            0.28 to -0.48,
            0.15 to -0.30,
        )
    pts.addAll(generateSpline(leafCtrls, 20, Color(0xFF7FFF00), Color(0xFF2ECC71), isClosed = true))
    return pts
}

internal fun generateBananaPoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val bananaCtrls =
        listOf(
            0.15 to -0.48,
            0.18 to -0.38,
            0.05 to -0.15,
            -0.12 to 0.08,
            -0.22 to 0.30,
            -0.24 to 0.40,
            -0.16 to 0.34,
            0.02 to 0.12,
            0.16 to -0.15,
            0.08 to -0.42,
        )
    val splinePoints = generateSpline(bananaCtrls, 45, Color(0xFFFFD700), Color(0xFFFF5E3A), isClosed = true)
    val texturedPoints =
        splinePoints.map { pt ->
            val color =
                when {
                    pt.progress < 0.18 -> Color(0xFF5C4033)
                    pt.progress < 0.28 -> Color(0xFF7FFF00)
                    pt.progress < 0.85 -> Color(0xFFFFD700)
                    else -> Color(0xFF2C3E50)
                }
            pt.copy(color = color)
        }
    pts.addAll(texturedPoints)
    return pts
}

internal fun generateCookiePoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val baseCtrls = ArrayList<Pair<Double, Double>>()
    val segments = 12
    for (i in 0 until segments) {
        val angle = PI * 2.0 * i.toDouble() / segments.toDouble()
        val bump = 0.03 * sin(angle * 3.5)
        val r = 0.45 + bump
        baseCtrls.add(cos(angle) * r to sin(angle) * r)
    }
    pts.addAll(generateSpline(baseCtrls, 30, Color(0xFFE5A96A), Color(0xFFC68B59), isClosed = true))

    val chipCenters =
        listOf(
            -0.15 to -0.15,
            0.18 to -0.10,
            0.05 to 0.18,
            -0.18 to 0.12,
            0.0 to -0.28,
        )
    for ((cx, cy) in chipCenters) {
        val chipCtrls =
            listOf(
                cx - 0.04 to cy,
                cx to cy - 0.03,
                cx + 0.05 to cy,
                cx to cy + 0.04,
            )
        pts.addAll(generateSpline(chipCtrls, 8, Color(0xFF3D2723), Color(0xFF1E1610), isClosed = true))
    }
    return pts
}

internal fun generateCupcakePoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val linerCtrls =
        listOf(
            -0.30 to 0.35,
            0.30 to 0.35,
            0.36 to 0.05,
            -0.36 to 0.05,
        )
    pts.addAll(generateSpline(linerCtrls, 40, Color(0xFF5DADE2), Color(0xFF3498DB), isClosed = true))

    val pleatsX = listOf(-0.2, -0.1, 0.0, 0.1, 0.2)
    for (px in pleatsX) {
        val startX = px * 0.9
        val endX = px * 1.05
        val pleatCtrls =
            listOf(
                startX to 0.35,
                (startX + endX) * 0.5 to 0.20,
                endX to 0.05,
            )
        pts.addAll(generateSpline(pleatCtrls, 12, Color(0xFF2E86C1), Color(0xFF5DADE2), isClosed = false))
    }

    val frostingCtrls =
        listOf(
            -0.38 to 0.05,
            -0.36 to -0.10,
            -0.28 to -0.15,
            -0.25 to -0.28,
            -0.14 to -0.32,
            0.0 to -0.45,
            0.14 to -0.32,
            0.25 to -0.28,
            0.28 to -0.15,
            0.36 to -0.10,
            0.38 to 0.05,
            0.0 to 0.08,
        )
    pts.addAll(generateSpline(frostingCtrls, 25, Color(0xFF8E44AD), Color(0xFFFFB7B2), isClosed = true))

    val cherryCtrls =
        listOf(
            0.0 to -0.46,
            0.05 to -0.51,
            0.0 to -0.56,
            -0.05 to -0.51,
        )
    pts.addAll(generateSpline(cherryCtrls, 12, Color(0xFFFF2A6D), Color(0xFFFF1493), isClosed = true))

    val stemCtrls =
        listOf(
            0.0 to -0.54,
            0.04 to -0.62,
            0.12 to -0.68,
        )
    pts.addAll(generateSpline(stemCtrls, 10, Color(0xFF8E5A32), Color(0xFF5C4033), isClosed = false))
    return pts
}
