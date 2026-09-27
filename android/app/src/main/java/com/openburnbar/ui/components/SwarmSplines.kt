package com.openburnbar.ui.components

import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.ui.graphics.Color
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Spline math, text rasterization, and badge-shape point generators. */
internal fun sampleTextPoints(text: String, fontSize: Float): List<Pair<Double, Double>> {
    val side = 400
    val bmp = Bitmap.createBitmap(side, side, Bitmap.Config.ALPHA_8)
    val canvas = android.graphics.Canvas(bmp)
    val paint =
        Paint().apply {
            isAntiAlias = true
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            textSize = fontSize
            textAlign = Paint.Align.CENTER
            color = 0xFFFFFFFF.toInt()
        }
    val metrics = paint.fontMetrics
    val baseline = side / 2f - (metrics.ascent + metrics.descent) / 2f
    canvas.drawText(text, side / 2f, baseline, paint)

    val pixels = IntArray(side * side)
    val argbBmp = bmp.copy(Bitmap.Config.ARGB_8888, false)
    argbBmp.getPixels(pixels, 0, side, 0, 0, side, side)

    val pts = ArrayList<Pair<Double, Double>>()
    val gap = 5
    var y = 0
    while (y < side) {
        var x = 0
        while (x < side) {
            if ((pixels[y * side + x] ushr 24) and 0xFF > 128) {
                pts.add(
                    ((x - side / 2).toDouble() / (side / 2)) to
                        ((y - side / 2).toDouble() / (side / 2)),
                )
            }
            x += gap
        }
        y += gap
    }
    bmp.recycle()
    argbBmp.recycle()
    return pts
}

internal fun splinePoints(controlPoints: List<Pair<Double, Double>>, stepsPerSegment: Int, role: String): List<ShapePoint> {
    if (controlPoints.size < 3) return emptyList()
    val pts = ArrayList<ShapePoint>()
    val n = controlPoints.size
    for (i in 0 until n) {
        val p0 = controlPoints[(i - 1 + n) % n]
        val p1 = controlPoints[i]
        val p2 = controlPoints[(i + 1) % n]
        val p3 = controlPoints[(i + 2) % n]
        for (j in 0 until stepsPerSegment) {
            val t = j.toDouble() / stepsPerSegment.toDouble()
            val t2 = t * t
            val t3 = t2 * t
            val x =
                0.5 * (
                    2.0 * p1.first +
                        (-p0.first + p2.first) * t +
                        (2.0 * p0.first - 5.0 * p1.first + 4.0 * p2.first - p3.first) * t2 +
                        (-p0.first + 3.0 * p1.first - 3.0 * p2.first + p3.first) * t3
                    )
            val y =
                0.5 * (
                    2.0 * p1.second +
                        (-p0.second + p2.second) * t +
                        (2.0 * p0.second - 5.0 * p1.second + 4.0 * p2.second - p3.second) * t2 +
                        (-p0.second + 3.0 * p1.second - 3.0 * p2.second + p3.second) * t3
                    )
            pts.add(ShapePoint(x, y, role, (i * stepsPerSegment + j).toDouble() / (n * stepsPerSegment).toDouble()))
        }
    }
    return pts
}

internal fun generateSpline(
    controlPoints: List<Pair<Double, Double>>,
    stepsPerSegment: Int,
    colorStart: Color,
    colorEnd: Color = colorStart,
    isClosed: Boolean = true,
    role: String = "cooking",
): List<ShapePoint> {
    if (controlPoints.isEmpty()) return emptyList()
    return if (isClosed) {
        closedSplinePoints(controlPoints, stepsPerSegment, colorStart, colorEnd, role)
    } else {
        openSplinePoints(controlPoints, stepsPerSegment, colorStart, colorEnd, role)
    }
}

private fun closedSplinePoints(
    controlPoints: List<Pair<Double, Double>>,
    stepsPerSegment: Int,
    colorStart: Color,
    colorEnd: Color,
    role: String,
): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val n = controlPoints.size
    if (n < 3) return emptyList()
    for (i in 0 until n) {
        val p0 = controlPoints[(i - 1 + n) % n]
        val p1 = controlPoints[i]
        val p2 = controlPoints[(i + 1) % n]
        val p3 = controlPoints[(i + 2) % n]
        for (j in 0 until stepsPerSegment) {
            val t = j.toDouble() / stepsPerSegment.toDouble()
            val t2 = t * t
            val t3 = t2 * t
            val x =
                0.5 * (
                    2.0 * p1.first +
                        (-p0.first + p2.first) * t +
                        (2.0 * p0.first - 5.0 * p1.first + 4.0 * p2.first - p3.first) * t2 +
                        (-p0.first + 3.0 * p1.first - 3.0 * p2.first + p3.first) * t3
                    )
            val y =
                0.5 * (
                    2.0 * p1.second +
                        (-p0.second + p2.second) * t +
                        (2.0 * p0.second - 5.0 * p1.second + 4.0 * p2.second - p3.second) * t2 +
                        (-p0.second + 3.0 * p1.second - 3.0 * p2.second + p3.second) * t3
                    )
            val progress = (i * stepsPerSegment + j).toDouble() / (n * stepsPerSegment).toDouble()
            val color = blend(colorStart, colorEnd, progress.toFloat())
            pts.add(ShapePoint(x, y, role, progress, color))
        }
    }
    return pts
}

private fun openSplinePoints(
    controlPoints: List<Pair<Double, Double>>,
    stepsPerSegment: Int,
    colorStart: Color,
    colorEnd: Color,
    role: String,
): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val n = controlPoints.size
    if (n < 2) return emptyList()
    val padded = ArrayList<Pair<Double, Double>>()
    padded.add(controlPoints.first())
    padded.addAll(controlPoints)
    padded.add(controlPoints.last())

    val pn = padded.size
    val segments = pn - 3
    for (i in 0 until segments) {
        val p0 = padded[i]
        val p1 = padded[i + 1]
        val p2 = padded[i + 2]
        val p3 = padded[i + 3]
        for (j in 0 until stepsPerSegment) {
            val t = j.toDouble() / stepsPerSegment.toDouble()
            val t2 = t * t
            val t3 = t2 * t
            val x =
                0.5 * (
                    2.0 * p1.first +
                        (-p0.first + p2.first) * t +
                        (2.0 * p0.first - 5.0 * p1.first + 4.0 * p2.first - p3.first) * t2 +
                        (-p0.first + 3.0 * p1.first - 3.0 * p2.first + p3.first) * t3
                    )
            val y =
                0.5 * (
                    2.0 * p1.second +
                        (-p0.second + p2.second) * t +
                        (2.0 * p0.second - 5.0 * p1.second + 4.0 * p2.second - p3.second) * t2 +
                        (-p0.second + 3.0 * p1.second - 3.0 * p2.second + p3.second) * t3
                    )
            val progress = (i * stepsPerSegment + j).toDouble() / (segments * stepsPerSegment).toDouble()
            val color = blend(colorStart, colorEnd, progress.toFloat())
            pts.add(ShapePoint(x, y, role, progress, color))
        }
    }
    return pts
}

internal fun generateRingPoints(numRings: Int = 3): List<Pair<Double, Double>> {
    val pts = ArrayList<Pair<Double, Double>>()
    for (ring in 0 until numRings) {
        val radius = 0.2 + ring * 0.25
        val count = 80 + ring * 50
        for (i in 0 until count) {
            val angle = i.toDouble() / count * PI * 2
            pts.add((cos(angle) * radius) to (sin(angle) * radius))
        }
    }
    return pts
}

internal fun generateRouterFlowPoints(): List<RoutePoint> {
    val pts = ArrayList<RoutePoint>()
    val gatewayCount = 100
    for (i in 0 until gatewayCount) {
        val angle = i.toDouble() / gatewayCount * PI * 2
        val r = 0.08
        pts.add(RoutePoint(-0.45 + cos(angle) * r, sin(angle) * r, "gateway", i.toDouble() / gatewayCount))
    }

    data class Tgt(val x: Double, val y: Double, val role: String)
    val targets =
        listOf(
            Tgt(0.45, -0.28, "target-1"),
            Tgt(0.45, 0.00, "target-2"),
            Tgt(0.45, 0.28, "target-3"),
        )
    for (tgt in targets) {
        val count = 50
        for (i in 0 until count) {
            val angle = i.toDouble() / count * PI * 2
            val r = 0.05
            pts.add(RoutePoint(tgt.x + cos(angle) * r, tgt.y + sin(angle) * r, tgt.role, i.toDouble() / count))
        }
    }
    for ((idx, tgt) in targets.withIndex()) {
        val count = 60
        val role = "path-${idx + 1}"
        for (i in 0 until count) {
            val t = i.toDouble() / count
            val px = -0.45 + (tgt.x - -0.45) * t
            val py = tgt.y * (3 * t * t - 2 * t * t * t)
            pts.add(RoutePoint(px, py, role, t))
        }
    }
    return pts
}
