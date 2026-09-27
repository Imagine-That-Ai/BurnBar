package com.openburnbar.ui.components

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.Color
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.models.logoRes
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.sqrt

/** Bitmap-sampled provider-logo point extraction (decode, flood fill, sampling). */
internal fun logoPoints(appContext: Context?, provider: AgentProvider, fallback: List<ShapePoint>): List<ShapePoint> {
    val context = appContext ?: return fallback
    val bitmap =
        BitmapFactory.decodeResource(context.resources, provider.logoRes)
            ?: return fallback
    return try {
        sampleLogoBitmap(bitmap, maxPoints = 1600).ifEmpty { fallback }
    } finally {
        bitmap.recycle()
    }
}

internal data class LogoBitmapBounds(val minX: Int, val minY: Int, val maxX: Int, val maxY: Int)

internal fun sampleLogoBitmap(bitmap: Bitmap, maxPoints: Int): List<ShapePoint> {
    val width = bitmap.width
    val height = bitmap.height
    if (width <= 0 || height <= 0) return emptyList()

    val pixels = IntArray(width * height)
    bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
    val background = inferredOpaqueBackgroundColor(pixels, width, height)
    val borderBackgroundMask = connectedBackgroundMask(pixels, width, height, background)
    val bounds = foregroundBoundingBox(pixels, width, height, borderBackgroundMask, background) ?: return emptyList()

    val points = sampleForegroundPoints(pixels, width, bounds, borderBackgroundMask, background, maxPoints)
    if (points.size <= maxPoints) return points
    return (0 until maxPoints).map { index ->
        val t = index.toDouble() / (maxPoints - 1).coerceAtLeast(1).toDouble()
        points[((points.size - 1) * t).toInt().coerceAtMost(points.size - 1)]
    }
}

internal fun foregroundBoundingBox(pixels: IntArray, width: Int, height: Int, borderBackgroundMask: BooleanArray?, background: Color?): LogoBitmapBounds? {
    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0
    for (y in 0 until height) {
        for (x in 0 until width) {
            val pixelIndex = y * width + x
            if (isLogoForegroundPixel(pixels[pixelIndex], pixelIndex, borderBackgroundMask, background)) {
                if (x < minX) minX = x
                if (y < minY) minY = y
                if (x > maxX) maxX = x
                if (y > maxY) maxY = y
            }
        }
    }
    if (minX > maxX || minY > maxY) return null
    return LogoBitmapBounds(minX, minY, maxX, maxY)
}

internal fun sampleForegroundPoints(
    pixels: IntArray,
    width: Int,
    bounds: LogoBitmapBounds,
    borderBackgroundMask: BooleanArray?,
    background: Color?,
    maxPoints: Int,
): List<ShapePoint> {
    val occupiedWidth = (bounds.maxX - bounds.minX + 1).coerceAtLeast(1)
    val occupiedHeight = (bounds.maxY - bounds.minY + 1).coerceAtLeast(1)
    val step = ceil(sqrt((occupiedWidth * occupiedHeight).toDouble() / maxPoints.toDouble())).toInt().coerceAtLeast(2)
    val centerX = (bounds.minX + bounds.maxX).toDouble() / 2.0
    val centerY = (bounds.minY + bounds.maxY).toDouble() / 2.0
    val scale = maxOf(occupiedWidth, occupiedHeight).toDouble() / 2.0
    val points = ArrayList<ShapePoint>(maxPoints)

    var y = bounds.minY
    while (y <= bounds.maxY) {
        var x = bounds.minX
        while (x <= bounds.maxX) {
            val pixel = pixels[y * width + x]
            val pixelIndex = y * width + x
            if (isLogoForegroundPixel(pixel, pixelIndex, borderBackgroundMask, background)) {
                val alpha = ((pixel ushr 24) and 0xFF) / 255f
                val red = ((pixel ushr 16) and 0xFF) / 255f
                val green = ((pixel ushr 8) and 0xFF) / 255f
                val blue = (pixel and 0xFF) / 255f
                val source = Color(red, green, blue, alpha)
                val luminance = 0.2126f * red + 0.7152f * green + 0.0722f * blue
                val role =
                    when {
                        luminance < 0.30f -> "logo-flame-outer"
                        luminance > 0.76f -> "logo-flame-spark"
                        else -> "logo-flame-inner"
                    }
                points.add(
                    ShapePoint(
                        x = (x.toDouble() - centerX) / scale,
                        y = (y.toDouble() - centerY) / scale,
                        role = role,
                        progress = (points.size % maxPoints).toDouble() / (maxPoints - 1).coerceAtLeast(1).toDouble(),
                        color = source,
                    ),
                )
            }
            x += step
        }
        y += step
    }
    return points
}

internal fun inferredOpaqueBackgroundColor(pixels: IntArray, width: Int, height: Int): Color? {
    val cornerSide = (min(width, height) / 10).coerceIn(1, 8)
    val xRanges = listOf(0 until cornerSide, (width - cornerSide).coerceAtLeast(0) until width)
    val yRanges = listOf(0 until cornerSide, (height - cornerSide).coerceAtLeast(0) until height)

    var red = 0f
    var green = 0f
    var blue = 0f
    var alpha = 0f
    var count = 0
    for (xRange in xRanges) {
        for (yRange in yRanges) {
            for (y in yRange) {
                for (x in xRange) {
                    val pixel = pixels[y * width + x]
                    val a = ((pixel ushr 24) and 0xFF) / 255f
                    if (a <= 0.85f) continue
                    alpha += a
                    red += ((pixel ushr 16) and 0xFF) / 255f
                    green += ((pixel ushr 8) and 0xFF) / 255f
                    blue += (pixel and 0xFF) / 255f
                    count += 1
                }
            }
        }
    }

    if (count < 4 || alpha / count <= 0.88f) return null
    return Color(red / count, green / count, blue / count, alpha / count)
}

internal fun connectedBackgroundMask(pixels: IntArray, width: Int, height: Int, background: Color?): BooleanArray? {
    if (background == null) return null
    val visited = BooleanArray(width * height)
    val queue = ArrayDeque<Int>()

    fun enqueue(x: Int, y: Int) {
        if (x !in 0 until width || y !in 0 until height) return
        val index = y * width + x
        if (visited[index]) return
        if (!isBackgroundLikePixel(pixels[index], background)) return
        visited[index] = true
        queue.add(index)
    }

    for (x in 0 until width) {
        enqueue(x, 0)
        enqueue(x, height - 1)
    }
    for (y in 0 until height) {
        enqueue(0, y)
        enqueue(width - 1, y)
    }

    while (queue.isNotEmpty()) {
        val index = queue.removeFirst()
        val x = index % width
        val y = index / width
        enqueue(x + 1, y)
        enqueue(x - 1, y)
        enqueue(x, y + 1)
        enqueue(x, y - 1)
    }

    return visited
}

internal fun isBackgroundLikePixel(pixel: Int, background: Color): Boolean {
    val alpha = ((pixel ushr 24) and 0xFF) / 255f
    if (alpha <= 0.22f) return true
    val red = ((pixel ushr 16) and 0xFF) / 255f
    val green = ((pixel ushr 8) and 0xFF) / 255f
    val blue = (pixel and 0xFF) / 255f
    val distance =
        sqrt(
            (
                (red - background.red) * (red - background.red) +
                    (green - background.green) * (green - background.green) +
                    (blue - background.blue) * (blue - background.blue)
                ).toDouble(),
        ).toFloat()
    val luminance = relativeLuminance(red, green, blue)
    val maxChannel = maxOf(red, green, blue)
    val minChannel = minOf(red, green, blue)
    val saturation = maxChannel - minChannel
    return distance < 0.12f || (relativeLuminance(background) > 0.86f && luminance > 0.88f && saturation < 0.10f)
}

internal fun isLogoForegroundPixel(pixel: Int, pixelIndex: Int, borderBackgroundMask: BooleanArray?, background: Color?): Boolean {
    val alpha = ((pixel ushr 24) and 0xFF) / 255f
    if (alpha <= 0.22f) return false
    borderBackgroundMask?.let { return pixelIndex !in it.indices || !it[pixelIndex] }

    val red = ((pixel ushr 16) and 0xFF) / 255f
    val green = ((pixel ushr 8) and 0xFF) / 255f
    val blue = (pixel and 0xFF) / 255f
    if (background == null) return true

    val distance =
        sqrt(
            (
                (red - background.red) * (red - background.red) +
                    (green - background.green) * (green - background.green) +
                    (blue - background.blue) * (blue - background.blue)
                ).toDouble(),
        ).toFloat()
    val luminance = relativeLuminance(red, green, blue)
    val maxChannel = maxOf(red, green, blue)
    val minChannel = minOf(red, green, blue)
    val saturation = maxChannel - minChannel

    if (distance < 0.09f) return false
    if (relativeLuminance(background) > 0.86f && luminance > 0.88f && saturation < 0.10f) return false
    return true
}
