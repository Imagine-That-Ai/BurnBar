package com.openburnbar.ui.components

import com.openburnbar.data.models.AgentProvider
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/** Provider-logo point tables: generated fallbacks plus bitmap sampling. */
internal fun providerLogoSlots(count: Int, width: Double, height: Double): List<ProviderLogoSlot> {
    if (count <= 0) return emptyList()
    if (count == 1) {
        return listOf(
            ProviderLogoSlot(
                centerX = if (width > 960) width * 0.74 else width * 0.5,
                centerY = if (width > 960) height * 0.30 else height * 0.24,
                scale = min(width, height) * 0.34,
            ),
        )
    }

    val maxColumns =
        when {
            width >= 1320 -> 5
            width >= 920 -> 4
            else -> 2
        }
    val columns = min(count, maxColumns)
    val rows = ceil(count.toDouble() / columns.toDouble()).toInt()
    val xStep = (width * 0.78 / (columns - 1).coerceAtLeast(1)).coerceIn(180.0, 300.0)
    val yStep = (height * 0.44 / (rows - 1).coerceAtLeast(1)).coerceIn(130.0, 210.0)
    val gridHeight = yStep * (rows - 1).coerceAtLeast(0)
    val gridCenterY = height * if (rows > 1) 0.40 else 0.34
    val scale =
        min(
            min(width, height) * 0.32,
            (min(xStep, if (rows > 1) yStep else height * 0.32) * 0.72).coerceAtLeast(110.0),
        )

    return (0 until count).map { index ->
        val row = index / columns
        val column = index % columns
        val rowCount = min(columns, count - row * columns)
        val rowWidth = xStep * (rowCount - 1).coerceAtLeast(0)
        ProviderLogoSlot(
            centerX = width * 0.5 - rowWidth / 2.0 + xStep * column,
            centerY = gridCenterY - gridHeight / 2.0 + yStep * row,
            scale = scale,
        )
    }
}

internal fun providerTextPoints(provider: AgentProvider): List<ShapePoint> {
    val data = SwarmTextCoordinates.getCoordinates(provider)
    val count = data.size / 2
    val pts = ArrayList<ShapePoint>(count)
    val denom = (count - 1).coerceAtLeast(1).toDouble()
    var idx = 0
    while (idx < data.size) {
        pts.add(
            ShapePoint(
                x = data[idx],
                y = data[idx + 1],
                role = "logo-flame-inner",
                progress = (idx / 2).toDouble() / denom,
            ),
        )
        idx += 2
    }
    return pts
}

internal fun fallbackLogoPoints(provider: AgentProvider): List<ShapePoint> = when (provider) {
    AgentProvider.OPEN_AI -> generateOpenAILogoPoints()
    AgentProvider.CODEX -> generateCodexLogoPoints()
    AgentProvider.CLAUDE_CODE -> generateAnthropicLogoPoints()
    AgentProvider.GEMINI_CLI -> generateGeminiLogoPoints()
    AgentProvider.ANTIGRAVITY -> generateAntigravityLogoPoints()
    AgentProvider.CURSOR -> generateCursorLogoPoints()
    AgentProvider.OPENCODE -> generateOpenCodeLogoPoints()
    AgentProvider.XAI -> generateXAILogoPoints()
    AgentProvider.OLLAMA -> generateOllamaLogoPoints()
    AgentProvider.HERMES -> generateHermesLogoPoints()
    else -> initialsLogoPoints(provider)
}

internal fun initialsLogoPoints(provider: AgentProvider): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()

    fun appendLine(startX: Double, startY: Double, endX: Double, endY: Double, count: Int, role: String) {
        for (i in 0 until count) {
            val t = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
            pts.add(
                ShapePoint(
                    x = startX + (endX - startX) * t,
                    y = startY + (endY - startY) * t,
                    role = role,
                    progress = t,
                ),
            )
        }
    }

    val sides = 3 + (provider.ordinal % 5)
    val radius = 0.34
    val vertices =
        (0 until sides).map { index ->
            val angle = -PI / 2.0 + (PI * 2.0 * index / sides)
            cos(angle) * radius to sin(angle) * radius
        }
    for (index in vertices.indices) {
        val start = vertices[index]
        val end = vertices[(index + 1) % vertices.size]
        appendLine(start.first, start.second, end.first, end.second, 42, "logo-flame-outer")
    }

    when (provider.ordinal % 4) {
        0 -> {
            appendLine(-0.20, -0.24, -0.20, 0.24, 70, "logo-flame-inner")
            appendLine(-0.20, 0.0, 0.20, 0.0, 70, "logo-flame-spark")
            appendLine(0.20, -0.24, 0.20, 0.24, 70, "logo-flame-inner")
        }
        1 -> {
            appendLine(-0.24, 0.24, 0.24, -0.24, 95, "logo-flame-inner")
            appendLine(-0.24, -0.24, 0.24, 0.24, 95, "logo-flame-spark")
        }
        2 -> {
            appendLine(-0.26, -0.20, 0.0, 0.26, 80, "logo-flame-inner")
            appendLine(0.0, 0.26, 0.26, -0.20, 80, "logo-flame-spark")
        }
        else -> {
            appendLine(-0.24, -0.22, 0.24, -0.22, 70, "logo-flame-inner")
            appendLine(-0.24, 0.0, 0.18, 0.0, 70, "logo-flame-spark")
            appendLine(-0.24, 0.22, 0.24, 0.22, 70, "logo-flame-inner")
        }
    }

    val denominator = (pts.size - 1).coerceAtLeast(1).toDouble()
    return pts.mapIndexed { index, point ->
        point.copy(progress = index.toDouble() / denominator)
    }
}

internal fun generateOpenAILogoPoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val a = 0.22
    val b = 0.07
    val d = 0.12
    val alpha = 0.2
    val steps = 70
    for (i in 0 until 6) {
        val theta = i.toDouble() * (PI / 3.0)
        for (j in 0 until steps) {
            val t = j.toDouble() / steps.toDouble() * (PI * 2.0)
            val localX = d + a * cos(t) * cos(alpha) - b * sin(t) * sin(alpha)
            val localY = a * cos(t) * sin(alpha) + b * sin(t) * cos(alpha)
            pts.add(
                ShapePoint(
                    x = localX * cos(theta) - localY * sin(theta),
                    y = localX * sin(theta) + localY * cos(theta),
                    role = "logo-flame-inner",
                    progress = j.toDouble() / steps.toDouble(),
                ),
            )
        }
    }
    return pts
}

internal fun generateAnthropicLogoPoints(): List<ShapePoint> {
    val outer =
        listOf(
            -0.22 to -0.30,
            -0.07 to 0.32,
            0.07 to 0.32,
            0.22 to -0.30,
            0.12 to -0.30,
            0.0 to 0.02,
            -0.12 to -0.30,
        )
    val inner = listOf(0.0 to 0.20, 0.05 to 0.08, -0.05 to 0.08)
    return splinePoints(outer, 35, "logo-flame-outer") +
        splinePoints(inner, 35, "logo-flame-inner")
}

internal fun generateGeminiLogoPoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()

    fun appendAstroid(radius: Double, count: Int, role: String) {
        for (i in 0 until count) {
            val t = i.toDouble() / count.toDouble() * (PI * 2.0)
            pts.add(
                ShapePoint(
                    x = radius * cos(t) * cos(t) * cos(t),
                    y = radius * sin(t) * sin(t) * sin(t),
                    role = role,
                    progress = i.toDouble() / count.toDouble(),
                ),
            )
        }
    }
    appendAstroid(0.34, 220, "logo-flame-outer")
    appendAstroid(0.18, 150, "logo-flame-inner")
    return pts
}

internal fun generateCursorLogoPoints(): List<ShapePoint> = splinePoints(
    listOf(0.0 to 0.32, 0.18 to -0.18, 0.0 to -0.05, -0.18 to -0.18),
    90,
    "logo-flame-inner",
)

internal fun generateOpenCodeLogoPoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()

    fun appendLine(startX: Double, startY: Double, endX: Double, endY: Double, count: Int, role: String) {
        for (i in 0 until count) {
            val t = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
            pts.add(
                ShapePoint(
                    x = startX + (endX - startX) * t,
                    y = startY + (endY - startY) * t,
                    role = role,
                    progress = t,
                ),
            )
        }
    }

    appendLine(-0.34, 0.0, -0.12, -0.22, 90, "logo-flame-outer")
    appendLine(-0.34, 0.0, -0.12, 0.22, 90, "logo-flame-inner")
    appendLine(0.34, 0.0, 0.12, -0.22, 90, "logo-flame-outer")
    appendLine(0.34, 0.0, 0.12, 0.22, 90, "logo-flame-inner")
    appendLine(-0.04, 0.30, 0.08, -0.30, 120, "logo-flame-spark")
    return pts
}

internal fun generateOllamaLogoPoints(): List<ShapePoint> {
    val coords = OLLAMA_LOGO_COORDS
    val pts = ArrayList<ShapePoint>()
    val count = coords.size / 2
    for (i in 0 until count) {
        val x = coords[i * 2]
        val y = coords[i * 2 + 1]
        val progress = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
        pts.add(
            ShapePoint(
                x = x,
                y = y,
                role = if (i % 3 == 0) "logo-flame-spark" else "logo-flame-inner",
                progress = progress,
            ),
        )
    }
    return pts
}

internal fun generateHermesLogoPoints(): List<ShapePoint> = HERMES_LOGO_POINTS

internal fun generateXAILogoPoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()
    val diagonalCount = 140
    for (i in 0 until diagonalCount) {
        val t = i.toDouble() / diagonalCount.toDouble()
        val x = -0.22 + t * 0.44
        val y = 0.25 - t * 0.50
        pts.add(ShapePoint(x - 0.015, y, "logo-flame-outer", t))
        pts.add(ShapePoint(x + 0.015, y, "logo-flame-inner", t))
    }
    val segmentCount = 60
    for (i in 0 until segmentCount) {
        val t = i.toDouble() / segmentCount.toDouble()
        pts.add(ShapePoint(-0.22 + t * 0.16, -0.25 + t * 0.18, "logo-flame-spark", t * 0.5))
        pts.add(ShapePoint(0.06 + t * 0.16, 0.07 + t * 0.18, "logo-flame-spark", 0.5 + t * 0.5))
    }
    return pts
}

internal fun generateGrokLogoPoints(): List<ShapePoint> {
    val pts = ArrayList<ShapePoint>()

    fun appendArc(radius: Double, start: Double, end: Double, count: Int, role: String) {
        for (i in 0 until count) {
            val t = i.toDouble() / (count - 1).coerceAtLeast(1).toDouble()
            val angle = start + (end - start) * t
            pts.add(ShapePoint(cos(angle) * radius, sin(angle) * radius, role, t))
        }
    }
    appendArc(0.34, 0.70, 2.85, 130, "logo-flame-outer")
    appendArc(0.23, 0.80, 2.65, 95, "logo-flame-inner")
    appendArc(0.34, 3.65, 6.02, 145, "logo-flame-outer")
    appendArc(0.23, 3.90, 5.78, 95, "logo-flame-inner")
    val slashCount = 180
    for (i in 0 until slashCount) {
        val t = i.toDouble() / (slashCount - 1).toDouble()
        val x = -0.42 + t * 0.84
        val y = 0.40 - t * 0.82
        val normal = 0.018
        for (lane in listOf(-1.0, 0.0, 1.0)) {
            pts.add(
                ShapePoint(
                    x = x + lane * normal,
                    y = y + lane * normal * 0.45,
                    role = if (lane == 0.0) "logo-flame-spark" else "logo-flame-inner",
                    progress = t,
                ),
            )
        }
    }
    return pts
}

internal fun generateCodexLogoPoints(): List<ShapePoint> {
    val leftBrace =
        listOf(
            -0.06 to 0.28,
            -0.18 to 0.26,
            -0.16 to 0.12,
            -0.28 to 0.0,
            -0.16 to -0.12,
            -0.18 to -0.26,
            -0.06 to -0.28,
        )
    val rightBrace =
        listOf(
            0.06 to 0.28,
            0.18 to 0.26,
            0.16 to 0.12,
            0.28 to 0.0,
            0.16 to -0.12,
            0.18 to -0.26,
            0.06 to -0.28,
        )
    val leftPts = splinePoints(leftBrace, stepsPerSegment = 50, role = "logo-flame-outer")
    val rightPts = splinePoints(rightBrace, stepsPerSegment = 50, role = "logo-flame-inner")
    return leftPts + rightPts
}

internal fun generateAntigravityLogoPoints(): List<ShapePoint> {
    val diamond =
        listOf(
            0.0 to 0.32,
            0.24 to 0.0,
            0.0 to -0.32,
            -0.24 to 0.0,
        )
    val triangle =
        listOf(
            0.0 to 0.12,
            0.10 to -0.08,
            -0.10 to -0.08,
        )
    val diamondPts = splinePoints(diamond, stepsPerSegment = 60, role = "logo-flame-outer")
    val trianglePts = splinePoints(triangle, stepsPerSegment = 60, role = "logo-flame-inner")
    return diamondPts + trianglePts
}
