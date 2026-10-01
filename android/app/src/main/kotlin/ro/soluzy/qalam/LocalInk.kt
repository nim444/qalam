package ro.soluzy.qalam

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.os.SystemClock
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * The phone's copy of the ink, so you can see on the pad what you've written. It follows the
 * same rules as the Mac's InkBoard (mac/Sources/Qalam/Ink.swift): sizes in Mac points, pressure
 * widths, highlighter, a laser that fades, an eraser that removes whole strokes, and the same
 * undo history. [reconcile] follows undo/clear done on the Mac (menu, hotkeys, fade-away).
 *
 * Points are stored normalised to the pad (0..1), so they stay put when the pad reshapes; each
 * stroke remembers which display it was written on, and only the current display's are drawn.
 */
class LocalInk {

    class Stroke(val tool: Int, val color: Int, val base: Float, val display: Int, val w: Float, val h: Float) {
        var xs = FloatArray(128); var ys = FloatArray(128); var ws = FloatArray(128) // ws in Mac points
        var n = 0
        private var pressure = -1f

        fun add(x: Float, y: Float, p: Float) {
            pressure = if (pressure < 0) p else pressure * 0.6f + p * 0.4f // as on the Mac
            if (n == xs.size) {
                xs = xs.copyOf(n * 2); ys = ys.copyOf(n * 2); ws = ws.copyOf(n * 2)
            }
            xs[n] = x
            ys[n] = y
            ws[n] = if (tool == HIGHLIGHTER) base * 4 else base * (0.35f + 0.95f * pressure.coerceIn(0f, 1f))
            n++
        }

        /** Whether an eraser of [radius] points at (x, y) touches this stroke (Mac points). */
        fun hit(x: Float, y: Float, radius: Float): Boolean {
            val reach = radius + (if (tool == HIGHLIGHTER) base * 4 else base * 1.3f) / 2
            val px = x * w
            val py = y * h
            if (n == 1) return hypot(xs[0] * w - px, ys[0] * h - py) <= reach
            for (i in 1 until n) {
                if (segDistance(px, py, xs[i - 1] * w, ys[i - 1] * h, xs[i] * w, ys[i] * h) <= reach) return true
            }
            return false
        }
    }

    private sealed interface Action
    private class Add(val s: Stroke) : Action
    private class Erase(val list: List<Stroke>) : Action
    private class Clear(val list: List<Stroke>) : Action

    private val strokes = ArrayList<Stroke>()
    private val history = ArrayList<Action>()
    var active: Stroke? = null
        private set
    private var erased: ArrayList<Stroke>? = null
    private var tool = -1
    private var eraserRadius = 15f
    private val laser = ArrayList<FloatArray>() // x, y, time (ms)
    private var lastEdit = 0L

    /** Bumped on every change to the finished strokes; the pad re-renders its cache when it moves. */
    var version = 0
        private set

    val laserActive: Boolean get() = laser.isNotEmpty()

    fun begin(x: Float, y: Float, p: Float, tool: Int, color: Int, size: Int, display: Int, w: Float, h: Float) {
        lastEdit = SystemClock.uptimeMillis()
        this.tool = tool
        val base = SIZES[size.coerceIn(0, SIZES.size - 1)]
        when (tool) {
            PEN, HIGHLIGHTER -> active = Stroke(tool, Palette.colors.getOrElse(color) { Palette.ACCENT }, base, display, w, h).also { it.add(x, y, p) }
            ERASER -> {
                erased = ArrayList()
                eraserRadius = base * 3
                erase(x, y, display)
            }
            LASER -> laser += floatArrayOf(x, y, SystemClock.uptimeMillis().toFloat())
        }
    }

    fun extend(x: Float, y: Float, p: Float, display: Int) {
        lastEdit = SystemClock.uptimeMillis()
        when (tool) {
            PEN, HIGHLIGHTER -> active?.add(x, y, p)
            ERASER -> erase(x, y, display)
            LASER -> laser += floatArrayOf(x, y, SystemClock.uptimeMillis().toFloat())
        }
    }

    fun end() {
        active?.let {
            strokes += it
            history += Add(it)
            version++
        }
        active = null
        erased?.let { if (it.isNotEmpty()) history += Erase(it) }
        erased = null
        tool = -1
    }

    fun undo() {
        val last = history.removeLastOrNull() ?: return
        when (last) {
            is Add -> strokes.remove(last.s)
            is Erase -> strokes += last.list
            is Clear -> strokes += last.list
        }
        lastEdit = SystemClock.uptimeMillis()
        version++
    }

    fun clear() {
        end()
        if (strokes.isEmpty()) return
        history += Clear(ArrayList(strokes))
        strokes.clear()
        lastEdit = SystemClock.uptimeMillis()
        version++
    }

    /**
     * Follows the Mac's ink after changes made there: an undo (its history is shorter than ours)
     * or a clear / fade-away (nothing left on the Mac). Waits until the pen has been quiet a
     * moment, so a pong from before our latest stroke can't undo it.
     */
    fun reconcile(macStrokes: Int, macHistory: Int) {
        if (active != null || SystemClock.uptimeMillis() - lastEdit < 1200) return
        while (history.size > macHistory) undo()
        if (macStrokes == 0 && strokes.isNotEmpty()) {
            if (history.size + 1 == macHistory) clear() else { strokes.clear(); version++ }
        }
    }

    private fun erase(x: Float, y: Float, display: Int) {
        val hit = strokes.filter { it.display == display && it.hit(x, y, eraserRadius) }
        if (hit.isEmpty()) return
        strokes.removeAll(hit.toSet())
        erased?.addAll(hit)
        version++
    }

    // MARK: Drawing (pad coordinates in px; `scale` = px per Mac point)

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val path = Path()

    /** Draws the finished strokes of [display] (into the pad's cache bitmap). */
    fun drawFinished(c: Canvas, pad: RectF, scale: Float, display: Int) {
        for (s in strokes) if (s.display == display) drawStroke(c, s, pad, scale)
    }

    fun drawActive(c: Canvas, pad: RectF, scale: Float) {
        active?.let { drawStroke(c, it, pad, scale) }
    }

    /** Draws the laser trail; returns false once it has faded completely. */
    fun drawLaser(c: Canvas, pad: RectF, scale: Float): Boolean {
        val now = SystemClock.uptimeMillis().toFloat()
        laser.removeAll { now - it[2] > LASER_LIFE_MS }
        if (laser.size < 2) return laser.isNotEmpty()
        paint.color = 0xFFFF2D55.toInt()
        for (i in 1 until laser.size) {
            val f = 1 - (now - laser[i][2]) / LASER_LIFE_MS
            paint.alpha = (255 * f).toInt().coerceIn(0, 255)
            paint.strokeWidth = max(1.5f, (2 + 5 * f) * scale)
            c.drawLine(pad.left + laser[i - 1][0] * pad.width(), pad.top + laser[i - 1][1] * pad.height(),
                pad.left + laser[i][0] * pad.width(), pad.top + laser[i][1] * pad.height(), paint)
        }
        paint.alpha = 255
        return true
    }

    private fun drawStroke(c: Canvas, s: Stroke, pad: RectF, scale: Float) {
        fun x(i: Int) = pad.left + s.xs[i] * pad.width()
        fun y(i: Int) = pad.top + s.ys[i] * pad.height()
        paint.color = s.color
        if (s.tool == HIGHLIGHTER) {
            // One path at 38 %, so the stroke never darkens where it crosses itself.
            paint.alpha = 97
            paint.strokeWidth = max(2f, s.ws[0] * scale)
            path.reset()
            path.moveTo(x(0), y(0))
            if (s.n == 1) path.lineTo(x(0) + 0.1f, y(0))
            for (i in 1 until s.n) {
                if (i == s.n - 1) path.lineTo(x(i), y(i)) else path.quadTo(x(i), y(i), (x(i) + x(i + 1)) / 2, (y(i) + y(i + 1)) / 2)
            }
            c.drawPath(path, paint)
            paint.alpha = 255
            return
        }
        if (s.n == 1) {
            paint.style = Paint.Style.FILL
            c.drawCircle(x(0), y(0), max(1f, s.ws[0] * scale / 2), paint)
            paint.style = Paint.Style.STROKE
            return
        }
        // Quadratic pieces between midpoints, each with its own width, as on the Mac.
        for (i in 0 until s.n) {
            val ax = if (i == 0) x(0) else (x(i - 1) + x(i)) / 2
            val ay = if (i == 0) y(0) else (y(i - 1) + y(i)) / 2
            val bx = if (i == s.n - 1) x(i) else (x(i) + x(i + 1)) / 2
            val by = if (i == s.n - 1) y(i) else (y(i) + y(i + 1)) / 2
            paint.strokeWidth = max(1.2f, s.ws[i] * scale)
            path.reset()
            path.moveTo(ax, ay)
            path.quadTo(x(i), y(i), bx, by)
            c.drawPath(path, paint)
        }
    }

    companion object {
        // Tool numbers, as on the wire
        const val PEN = 0
        const val HIGHLIGHTER = 1
        const val LASER = 2
        const val ERASER = 3

        val SIZES = floatArrayOf(3f, 5f, 9f) // points, as Palette.sizes on the Mac
        const val LASER_LIFE_MS = 750f

        private fun segDistance(px: Float, py: Float, ax: Float, ay: Float, bx: Float, by: Float): Float {
            val dx = bx - ax
            val dy = by - ay
            val len2 = dx * dx + dy * dy
            val t = if (len2 > 0) min(1f, max(0f, ((px - ax) * dx + (py - ay) * dy) / len2)) else 0f
            return hypot(px - (ax + t * dx), py - (ay + t * dy))
        }
    }
}
