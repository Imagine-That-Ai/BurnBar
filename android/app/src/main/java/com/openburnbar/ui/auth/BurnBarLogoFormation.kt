package com.openburnbar.ui.auth

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import com.openburnbar.R
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.random.Random

/**
 * The launch hero, ported from the shared iOS/macOS `BurnBarLogoFormationView`.
 * A swarm of dots converges into the BurnBar flame, morphs to the solid logo, an
 * isometric glass cube settles around it, real domain-warped oil-on-water drifts
 * across the glass, and provider dot-glyphs form, drift under the glass, and
 * re-form into a new provider when two collide.
 *
 * minSdk 26 has no Liquid Glass / AGSL, so the oil is a CPU bitmap and the glass
 * is a layered translucent approximation — visually matched to the Apple build.
 */

// ---- design canvas (scaled to fit) ----
private const val DW = 560f
private const val DH = 460f
private const val LOGO_SIZE = 150f
private const val LOGO_CX = 280f
private const val LOGO_CY = 235f
private const val CUBE_S = 165f
private const val CUBE_CX = 280f
private const val CUBE_CY = 235f
private const val GLYPH_START_T = 5.8

// ---- math ----
private fun smooth(x: Double): Double {
    val t = x.coerceIn(0.0, 1.0)
    return t * t * (3 - 2 * t)
}
private fun easeOut(x: Double): Double {
    val t = x.coerceIn(0.0, 1.0)
    return 1 - (1 - t).pow(3.0)
}
private fun lerp(a: Float, b: Float, t: Double): Float = a + (b - a) * t.toFloat()
private fun fract(x: Double): Double = x - floor(x)
private fun clamp01(x: Double): Double = x.coerceIn(0.0, 1.0)

private fun hash21(x: Double, y: Double): Double {
    var px = fract(x * 123.34)
    var py = fract(y * 233.53)
    val dv = px * (px + 23.234) + py * (py + 23.234)
    px += dv
    py += dv
    return fract(px * py)
}
private fun vnoise(x: Double, y: Double): Double {
    val ix = floor(x)
    val iy = floor(y)
    val fx = x - ix
    val fy = y - iy
    val ux = fx * fx * (3 - 2 * fx)
    val uy = fy * fy * (3 - 2 * fy)
    val a = hash21(ix, iy)
    val b = hash21(ix + 1, iy)
    val c = hash21(ix, iy + 1)
    val d = hash21(ix + 1, iy + 1)
    val ab = a + (b - a) * ux
    val cd = c + (d - c) * ux
    return ab + (cd - ab) * uy
}
private fun fbm2(x0: Double, y0: Double): Double {
    var x = x0
    var y = y0
    var v = 0.0
    var amp = 0.5
    repeat(5) {
        v += amp * vnoise(x, y)
        val nx = 1.6 * x + 1.2 * y
        val ny = -1.2 * x + 1.6 * y
        x = nx
        y = ny
        amp *= 0.5
    }
    return v
}

// ---- model ----
private class Dot(
    val target: Offset,
    val start: Offset,
    val r: Double,
    val g: Double,
    val b: Double,
    val delay: Double,
    val driftA: Float,
    val driftF: Double,
    val driftP: Double,
    val dotSize: Double,
)
private class GDot(val px: Float, val py: Float, val r: Double, val g: Double, val b: Double)
private class Glyph(
    var x: Float,
    var y: Float,
    var vx: Float,
    var vy: Float,
    var prov: Int,
    var flash: Double,
    var formT: Double,
    var seed: Long,
)

private fun sampleDots(bmp: Bitmap?): List<Dot> {
    bmp ?: return emptyList()
    val w = bmp.width
    val h = bmp.height
    val grid = 62
    val raw = ArrayList<Triple<Offset, DoubleArray, Unit>>()
    val rng = Random(42)
    val out = ArrayList<Dot>()
    for (gy in 0 until grid) for (gx in 0 until grid) {
        val px = (((gx + 0.5) / grid) * w).toInt().coerceIn(0, w - 1)
        val py = (((gy + 0.5) / grid) * h).toInt().coerceIn(0, h - 1)
        val c = bmp.getPixel(px, py)
        val a = ((c ushr 24) and 0xff) / 255.0
        if (a < 0.45) continue
        val r = ((c ushr 16) and 0xff) / 255.0
        val g = ((c ushr 8) and 0xff) / 255.0
        val b = (c and 0xff) / 255.0
        val nx = (gx + 0.5) / grid
        val ny = (gy + 0.5) / grid
        raw.add(Triple(Offset(nx.toFloat(), ny.toFloat()), doubleArrayOf(r, g, b), Unit))
    }
    val logoOX = LOGO_CX - LOGO_SIZE / 2
    val logoOY = LOGO_CY - LOGO_SIZE / 2
    for ((n, col, _) in raw) {
        val tx = logoOX + n.x * LOGO_SIZE
        val ty = logoOY + n.y * LOGO_SIZE
        val ang = rng.nextDouble() * 2 * Math.PI
        val rad = (0.35 + rng.nextDouble() * 0.75) * maxOf(DW, DH).toDouble() * 0.6
        val sx = (LOGO_CX + cos(ang) * rad).toFloat()
        val sy = (LOGO_CY + sin(ang) * rad).toFloat()
        val delay = (0.04 + rng.nextDouble() * 0.22 + n.y.toDouble() * 0.06).coerceAtMost(0.30)
        out.add(
            Dot(
                Offset(tx, ty), Offset(sx, sy), col[0], col[1], col[2], delay,
                (8 + rng.nextDouble() * 22).toFloat(), 0.5 + rng.nextDouble() * 1.3, rng.nextDouble() * 6.28, 2.2 + rng.nextDouble() * 2.2,
            ),
        )
    }
    return out
}

private fun sampleGlyph(bmp: Bitmap?, grid: Int = 40, maxDots: Int = 220): List<GDot> {
    bmp ?: return emptyList()
    val w = bmp.width
    val h = bmp.height
    val pts = ArrayList<GDot>()
    for (gy in 0 until grid) for (gx in 0 until grid) {
        val px = (((gx + 0.5) / grid) * w).toInt().coerceIn(0, w - 1)
        val py = (((gy + 0.5) / grid) * h).toInt().coerceIn(0, h - 1)
        val c = bmp.getPixel(px, py)
        val a = ((c ushr 24) and 0xff) / 255.0
        var r = ((c ushr 16) and 0xff) / 255.0
        var g = ((c ushr 8) and 0xff) / 255.0
        var b = (c and 0xff) / 255.0
        val lum = 0.299 * r + 0.587 * g + 0.114 * b
        if (a > 0.4 && lum < 0.985) {
            val mx = maxOf(r, maxOf(g, b))
            if (mx < 0.06) {
                r = 0.92
                g = 0.94
                b = 0.97
            } else if (mx < 0.62) {
                val s = 0.62 / mx
                r = min(1.0, r * s)
                g = min(1.0, g * s)
                b = min(1.0, b * s)
            }
            pts.add(GDot((gx.toFloat() / (grid - 1) - 0.5f), (gy.toFloat() / (grid - 1) - 0.5f), r, g, b))
        }
    }
    if (pts.size > maxDots) {
        val step = pts.size.toDouble() / maxDots
        return (0 until maxDots).map { pts[min((it * step).toInt(), pts.size - 1)] }
    }
    return pts
}

private fun scatterOffset(seed: Long, k: Int): Offset {
    var s = seed + k.toLong() * 0x9E3779B97F4A7C15uL.toLong()
    s = s xor (s ushr 33)
    s *= 0xff51afd7ed558ccduL.toLong()
    s = s xor (s ushr 33)
    val a = ((s % 10000 + 10000) % 10000) / 10000.0 * 2 * Math.PI
    val r = 30 + (((s ushr 20) % 10000 + 10000) % 10000) / 10000.0 * 55
    return Offset((cos(a) * r).toFloat(), (sin(a) * r).toFloat())
}

// ---- isometric cube geometry ----
private class CubePts(
    val a: Offset,
    val b: Offset,
    val c: Offset,
    val d: Offset,
    val e: Offset,
    val f: Offset,
    val g: Offset,
)
private fun cubePoints(): CubePts {
    fun p(x: Float, y: Float, z: Float) = Offset(CUBE_CX + (x - y) * 0.866f * CUBE_S, CUBE_CY + ((x + y) * 0.5f - z) * CUBE_S)
    return CubePts(p(0f, 0f, 1f), p(1f, 0f, 1f), p(1f, 1f, 1f), p(0f, 1f, 1f), p(1f, 0f, 0f), p(1f, 1f, 0f), p(0f, 1f, 0f))
}
private fun roundedPoly(pts: List<Offset>, rad: Float): Path {
    val path = Path()
    val n = pts.size
    for (i in 0 until n) {
        val prev = pts[(i - 1 + n) % n]
        val cur = pts[i]
        val nxt = pts[(i + 1) % n]
        val v1x = cur.x - prev.x
        val v1y = cur.y - prev.y
        val v2x = nxt.x - cur.x
        val v2y = nxt.y - cur.y
        val l1 = maxOf(hypot(v1x, v1y), 0.001f)
        val l2 = maxOf(hypot(v2x, v2y), 0.001f)
        val r = minOf(rad, l1 / 2, l2 / 2)
        val p1 = Offset(cur.x - v1x / l1 * r, cur.y - v1y / l1 * r)
        val p2 = Offset(cur.x + v2x / l2 * r, cur.y + v2y / l2 * r)
        if (i == 0) path.moveTo(p1.x, p1.y) else path.lineTo(p1.x, p1.y)
        path.quadraticBezierTo(cur.x, cur.y, p2.x, p2.y)
    }
    path.close()
    return path
}
private fun cubeSil(p: CubePts) = roundedPoly(listOf(p.a, p.b, p.e, p.f, p.g, p.d), CUBE_S * 0.09f)
private fun cubeTop(p: CubePts) = roundedPoly(listOf(p.a, p.b, p.c, p.d), CUBE_S * 0.05f)
private fun cubeLeft(p: CubePts) = roundedPoly(listOf(p.d, p.c, p.f, p.g), CUBE_S * 0.05f)
private fun cubeRight(p: CubePts) = roundedPoly(listOf(p.b, p.e, p.f, p.c), CUBE_S * 0.05f)
private fun lineP(a: Offset, b: Offset): Path = Path().apply {
    moveTo(a.x, a.y)
    lineTo(b.x, b.y)
}

private fun hx(s: String): Color {
    val v = s.removePrefix("#").toLong(16)
    return Color(red = ((v shr 16) and 0xff).toInt(), green = ((v shr 8) and 0xff).toInt(), blue = (v and 0xff).toInt())
}

private fun stepSim(t: Double, dt: Double, glyphs: MutableList<Glyph>, n: Int) {
    if (t <= GLYPH_START_T) return
    val r = 44f
    for (gl in glyphs) {
        gl.x += gl.vx * dt.toFloat()
        gl.y += gl.vy * dt.toFloat()
        if (gl.x < 85) {
            gl.x = 85f
            gl.vx = kotlin.math.abs(gl.vx)
        }
        if (gl.x > DW - 85) {
            gl.x = DW - 85
            gl.vx = -kotlin.math.abs(gl.vx)
        }
        if (gl.y < 100) {
            gl.y = 100f
            gl.vy = kotlin.math.abs(gl.vy)
        }
        if (gl.y > 360) {
            gl.y = 360f
            gl.vy = -kotlin.math.abs(gl.vy)
        }
        if (gl.flash > 0) gl.flash = maxOf(0.0, gl.flash - dt * 2.2)
        if (gl.formT < 1) gl.formT = min(1.0, gl.formT + dt / 1.6)
    }
    for (i in 0 until glyphs.size - 1) for (j in i + 1 until glyphs.size) {
        val a = glyphs[i]
        val b = glyphs[j]
        val dx = b.x - a.x
        val dy = b.y - a.y
        val d = hypot(dx, dy)
        if (d < r * 2 && d > 0.001f) {
            val nx = dx / d
            val ny = dy / d
            val overlap = (r * 2 - d) / 2
            a.x -= nx * overlap
            a.y -= ny * overlap
            b.x += nx * overlap
            b.y += ny * overlap
            val pi = a.vx * nx + a.vy * ny
            val pj = b.vx * nx + b.vy * ny
            a.vx += (pj - pi) * nx
            a.vy += (pj - pi) * ny
            b.vx += (pi - pj) * nx
            b.vy += (pi - pj) * ny
            if (n > 1) {
                a.prov = (a.prov + Random.nextInt(1, n)) % n
                b.prov = (b.prov + Random.nextInt(1, n)) % n
            }
            a.formT = 0.0
            a.seed = Random.nextLong()
            b.formT = 0.0
            b.seed = Random.nextLong()
            a.flash = 1.0
            b.flash = 1.0
        }
    }
}

@Composable
fun BurnBarLogoFormation(modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val logoBmp = remember { runCatching { BitmapFactory.decodeResource(ctx.resources, R.drawable.logo_app) }.getOrNull() }
    val dots = remember { sampleDots(logoBmp) }
    val providerDots = remember {
        listOf(
            R.drawable.logo_anthropic,
            R.drawable.logo_open_ai,
            R.drawable.google_logo,
            R.drawable.logo_mistral,
            R.drawable.logo_meta,
            R.drawable.logo_grok,
            R.drawable.logo_deep_seek,
            R.drawable.logo_qwen,
        ).map { sampleGlyph(runCatching { BitmapFactory.decodeResource(ctx.resources, it) }.getOrNull()) }
    }
    val logoImg: ImageBitmap? = remember { logoBmp?.asImageBitmap() }
    val providerCount = maxOf(1, providerDots.size)

    var t by remember { mutableStateOf(0.0) }
    val glyphs = remember {
        mutableListOf<Glyph>().apply {
            repeat(3) { i ->
                add(
                    Glyph(
                        Random.nextDouble(120.0, (DW - 120).toDouble()).toFloat(),
                        Random.nextDouble(115.0, 345.0).toFloat(),
                        Random.nextDouble(-14.0, 14.0).toFloat(),
                        Random.nextDouble(-14.0, 14.0).toFloat(),
                        (i * 3) % providerCount,
                        0.0,
                        0.0,
                        Random.nextLong(),
                    ),
                )
            }
        }
    }
    val oilBmp = remember { Bitmap.createBitmap(68, 68, Bitmap.Config.ARGB_8888) }
    val oilPx = remember { IntArray(68 * 68) }

    LaunchedEffect(Unit) {
        var last = 0L
        while (true) {
            withFrameNanos { now ->
                if (last == 0L) last = now
                val dt = ((now - last).toDouble() / 1e9).coerceAtMost(0.05)
                last = now
                t += dt
                stepSim(t, dt, glyphs, providerCount)
            }
        }
    }

    Canvas(modifier = modifier) {
        val s = min(size.width / DW, size.height / DH)
        val ox = (size.width - DW * s) / 2f
        val oy = (size.height - DH * s) / 2f
        translate(ox, oy) {
            scale(s, s, pivot = Offset.Zero) { drawFormation(t, glyphs, dots, providerDots, logoImg, oilBmp, oilPx) }
        }
    }
}

private fun DrawScope.drawFormation(
    t: Double,
    glyphs: List<Glyph>,
    dots: List<Dot>,
    providerDots: List<List<GDot>>,
    logoImg: ImageBitmap?,
    oilBmp: Bitmap,
    oilPx: IntArray,
) {
    val p = min(t / 5.0, 1.0)
    val solidFade = smooth((p - 0.60) / 0.20)
    val glass = smooth((p - 0.80) / 0.20)
    val pts = cubePoints()
    val sil = cubeSil(pts)

    // converging dot swarm
    val conv = p - 0.10
    for (d in dots) {
        val local = easeOut((conv - d.delay) / 0.42)
        val drift = sin(d.driftP + p * 6.28 * d.driftF) * (if (p < 0.30) 1.0 else 1 - local)
        val fx = d.start.x + d.driftA * drift.toFloat()
        val fy = d.start.y + d.driftA * (cos(d.driftP + p * 5.0 * d.driftF)).toFloat() * (if (p < 0.30) 1f else (1 - local).toFloat())
        val x = lerp(fx, d.target.x, local)
        val y = lerp(fy, d.target.y, local)
        val appear = smooth(p / 0.12)
        val alpha = appear * (1 - solidFade * 0.92) * (0.45 + 0.55 * local)
        if (alpha <= 0.01) continue
        val warm = local
        val cr = 0.55 + (d.r - 0.55) * warm
        val cg = 0.40 + (d.g - 0.40) * warm
        val cb = 0.45 + (d.b - 0.45) * warm
        val ds = (d.dotSize * (1 + 0.7 * (1 - local))).toFloat()
        drawCircle(Color(cr.toFloat(), cg.toFloat(), cb.toFloat(), alpha.toFloat()), ds / 2, Offset(x, y))
    }

    // isometric glass cube
    if (glass > 0.001) {
        // contact shadow
        drawOval(
            Color.Black.copy(alpha = 0.5f * glass.toFloat()),
            topLeft = Offset(CUBE_CX - CUBE_S * 0.85f, pts.f.y + CUBE_S * 0.1f - CUBE_S * 0.23f),
            size = Size(CUBE_S * 1.7f, CUBE_S * 0.46f),
        )
        clipPath(sil) {
            drawPath(cubeRight(pts), hx("0C0D14"))
            drawPath(cubeRight(pts), hx("171924").copy(alpha = glass.toFloat()))
            drawPath(cubeRight(pts), brushVert(hx("171924"), hx("0C0D14"), pts.b.y, pts.f.y))
            drawPath(cubeLeft(pts), brushVert(hx("21232F"), hx("15161F"), pts.d.y, pts.g.y))
            drawPath(cubeTop(pts), brushVert(hx("3B3D49"), hx("2C2E38"), pts.a.y, pts.c.y))
        }
        // provider glyphs UNDER the glass
        val glyphAppear = smooth((t - GLYPH_START_T) / 1.2)
        if (glyphAppear > 0.001 && providerDots.isNotEmpty()) {
            for (gl in glyphs) {
                val gd = providerDots.getOrNull(gl.prov) ?: continue
                val f = easeOut(gl.formT)
                for ((k, d) in gd.withIndex()) {
                    val tx = gl.x + d.px * 98f
                    val ty = gl.y + d.py * 98f
                    val off = scatterOffset(gl.seed, k)
                    val sx = gl.x + off.x * 1.5f
                    val sy = gl.y + off.y * 1.5f
                    val x = sx + (tx - sx) * f.toFloat()
                    val y = sy + (ty - sy) * f.toFloat()
                    val alpha = min(1.0, glyphAppear * (0.22 + 0.78 * f) * (0.92 + 0.5 * gl.flash))
                    if (alpha < 0.02) continue
                    val ds = (3.1 + 1.8 * gl.flash).toFloat()
                    drawCircle(Color(d.r.toFloat(), d.g.toFloat(), d.b.toFloat(), alpha.toFloat()), ds / 2, Offset(x, y), blendMode = BlendMode.Plus)
                }
            }
        }
        // glass approximation: translucent sheen + highlights (no Liquid Glass on Android)
        clipPath(sil) {
            drawPath(cubeTop(pts), Color.White.copy(alpha = 0.10f))
            drawCircle(hx("F25205").copy(alpha = 0.16f), CUBE_S * 0.66f, Offset(CUBE_CX, CUBE_CY + CUBE_S * 0.18f), blendMode = BlendMode.Plus)
        }
        // internal edges (clipped)
        clipPath(sil) {
            val topEdge = Path().apply {
                moveTo(pts.d.x, pts.d.y)
                lineTo(pts.c.x, pts.c.y)
                lineTo(pts.b.x, pts.b.y)
            }
            drawPath(topEdge, hx("6E7180").copy(alpha = 0.85f), style = Stroke(width = maxOf(1f, CUBE_S * 0.012f)))
            drawPath(topEdge, Color.White.copy(alpha = 0.16f), style = Stroke(width = maxOf(0.5f, CUBE_S * 0.004f)))
            drawPath(lineP(pts.c, pts.f), brushVert(hx("5C5E6C"), hx("23242C"), pts.c.y, pts.f.y), style = Stroke(width = maxOf(1f, CUBE_S * 0.012f)))
        }
    }

    // solid logo morph-in
    if (solidFade > 0.001 && logoImg != null) {
        val sz = (LOGO_SIZE * (0.92 + 0.08 * solidFade)).toFloat()
        drawImageFitted(logoImg, Offset(LOGO_CX, LOGO_CY), sz, solidFade.toFloat())
    }

    // real oil + rim
    if (glass > 0.001) {
        computeOil(t, oilBmp, oilPx)
        clipPath(sil) {
            drawImage(
                oilBmp.asImageBitmap(),
                dstOffset = IntOffset((CUBE_CX - CUBE_S).toInt(), (CUBE_CY - CUBE_S).toInt()),
                dstSize = IntSize((CUBE_S * 2).toInt(), (CUBE_S * 2).toInt()),
                alpha = 0.95f,
                blendMode = BlendMode.Plus,
            )
        }
        drawPath(sil, Color.Black.copy(alpha = 0.5f), style = Stroke(width = maxOf(0.6f, CUBE_S * 0.006f)))
        drawPath(sil, Color.White.copy(alpha = 0.22f), style = Stroke(width = maxOf(0.8f, CUBE_S * 0.006f)))
    }
}

private fun DrawScope.brushVert(top: Color, bottom: Color, y0: Float, y1: Float) =
    androidx.compose.ui.graphics.Brush.verticalGradient(listOf(top, bottom), startY = y0, endY = y1)

private fun DrawScope.drawImageFitted(img: ImageBitmap, center: Offset, size: Float, alpha: Float) {
    val iw = img.width.toFloat()
    val ih = img.height.toFloat()
    val sc = size / maxOf(iw, ih)
    val w = iw * sc
    val h = ih * sc
    drawImage(
        img,
        dstOffset = IntOffset((center.x - w / 2).toInt(), (center.y - h / 2).toInt()),
        dstSize = IntSize(w.toInt(), h.toInt()),
        alpha = alpha,
    )
}

private fun computeOil(t: Double, bmp: Bitmap, px: IntArray) {
    val n = 68
    for (yy in 0 until n) for (xx in 0 until n) {
        val ux = (xx + 0.5) / n
        val uy = (yy + 0.5) / n
        val pxn = ux * 3.2
        val pyn = uy * 3.2
        val qx = fbm2(pxn + 0.15 * t, pyn + 0.15 * t)
        val qy = fbm2(pxn + 5.2 + 0.12 * t, pyn + 1.3 + 0.12 * t)
        val rx = fbm2(pxn + 2 * qx + 1.7 + 0.10 * t, pyn + 2 * qy + 9.2 + 0.10 * t)
        val ry = fbm2(pxn + 2 * qx + 8.3 - 0.13 * t, pyn + 2 * qy + 2.8 - 0.13 * t)
        val f = fbm2(pxn + 2 * rx, pyn + 2 * ry)
        val ph = f * 1.7 + 0.08 * t + hypot(rx, ry) * 0.8
        fun pal(o: Double) = clamp01(0.5 + 0.5 * cos(2 * Math.PI * (ph + o))).pow(1.25)
        val cr = pal(0.0)
        val cg = pal(0.33)
        val cb = pal(0.67)
        val wander = smooth((fbm2(ux * 1.3, uy * 1.3 - 0.05 * t) - 0.30) / 0.65)
        val patches = smooth((f - 0.52) / 0.40)
        val dxc = ux - 0.5
        val dyc = uy - 0.5
        val edge = 1 - smooth((hypot(dxc, dyc) * 1.45 - 0.62) / 0.46)
        val m = maxOf(0.0, patches * wander * edge) * 0.9
        val a = (m * 255).toInt().coerceIn(0, 255)
        val rr = (cr * 255).toInt().coerceIn(0, 255)
        val gg = (cg * 255).toInt().coerceIn(0, 255)
        val bb = (cb * 255).toInt().coerceIn(0, 255)
        px[yy * n + xx] = (a shl 24) or (rr shl 16) or (gg shl 8) or bb
    }
    bmp.setPixels(px, 0, n, 0, 0, n, n)
}
