package ro.soluzy.qalam

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.HapticFeedbackConstants
import android.view.View

/** Colours and sizes shared with the Mac by index (mac/Sources/Qalam/Palette.swift). */
object Palette {
    val colors = intArrayOf(
        0xFFFF3B30.toInt(), 0xFFFFD60A.toInt(), 0xFF30D158.toInt(),
        0xFF0A84FF.toInt(), 0xFF1C1C1E.toInt(), 0xFFFFFFFF.toInt(),
    )
    val sizes = arrayOf("S", "M", "L")

    const val ACCENT = 0xFF4FD1C5.toInt()
    const val SURFACE = 0xFF1C1C21.toInt()
    const val TEXT = 0xFFECECEC.toInt()
    const val MUTED = 0xFF9A9AA2.toInt()
}

/** Ink tools, numbered as on the wire. */
enum class Tool(val icon: Icon) { PEN(Icon.PEN), HIGHLIGHTER(Icon.HIGHLIGHTER), LASER(Icon.LASER), ERASER(Icon.ERASER) }

enum class Icon { PEN, HIGHLIGHTER, LASER, ERASER, UNDO, CLEAR }

/** Base for the strip's buttons: a rounded tile that lights up in the accent colour when selected (`isSelected`). */
abstract class StripButton(context: Context) : View(context) {
    protected val dp = resources.displayMetrics.density
    protected val tile = Paint(Paint.ANTI_ALIAS_FLAG)
    private val box = RectF()

    init {
        isClickable = true
        isFocusable = true
    }

    fun onTap(action: () -> Unit) = setOnClickListener {
        it.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        action()
    }

    protected fun drawTile(canvas: Canvas) {
        box.set(1f, 1f, width - 1f, height - 1f)
        tile.color = if (isSelected) Palette.ACCENT else Palette.SURFACE
        canvas.drawRoundRect(box, 10 * dp, 10 * dp, tile)
    }

    protected val ink: Int get() = if (isSelected) 0xFF0B0B0D.toInt() else Palette.TEXT
}

class Chip(context: Context, var label: String) : StripButton(context) {
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        textSize = 13 * dp
        isFakeBoldText = true
    }

    fun setText(value: String) {
        if (value != label) {
            label = value
            invalidate()
        }
    }

    override fun onDraw(canvas: Canvas) {
        drawTile(canvas)
        text.color = ink
        val label = fit(label, text, width - 16 * dp)
        canvas.drawText(label, width / 2f, height / 2f - (text.descent() + text.ascent()) / 2, text)
    }
}

class IconButton(context: Context, private val icon: Icon) : StripButton(context) {
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun onDraw(canvas: Canvas) {
        drawTile(canvas)
        val size = minOf(width, height) * 0.62f
        stroke.color = ink
        fill.color = ink
        canvas.save()
        canvas.translate((width - size) / 2, (height - size) / 2)
        canvas.scale(size / 24f, size / 24f)
        stroke.strokeWidth = 1.8f
        Icons.draw(canvas, icon, stroke, fill)
        canvas.restore()
    }
}

/** A colour dot; selected = a ring around it. */
class Swatch(context: Context, private val color: Int) : StripButton(context) {
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }

    override fun onDraw(canvas: Canvas) {
        val r = minOf(width, height) / 2f
        val cx = width / 2f
        val cy = height / 2f
        dot.color = color
        canvas.drawCircle(cx, cy, r * 0.62f, dot)
        ring.strokeWidth = 1 * dp
        ring.color = 0x55FFFFFF
        canvas.drawCircle(cx, cy, r * 0.62f, ring) // keeps black and dark colours visible
        if (isSelected) {
            ring.strokeWidth = 2.2f * dp
            ring.color = Palette.TEXT
            canvas.drawCircle(cx, cy, r * 0.9f, ring)
        }
    }
}

/** Icons on a 24-unit grid, drawn with the given paints (stroke 1.8). */
private object Icons {
    private val p = Path()

    fun draw(c: Canvas, icon: Icon, s: Paint, f: Paint) {
        p.reset()
        when (icon) {
            Icon.PEN -> {
                p.moveTo(4f, 20f); p.lineTo(5f, 15.5f); p.lineTo(15.5f, 5f); p.lineTo(19f, 8.5f); p.lineTo(8.5f, 19f); p.close()
                p.moveTo(13.5f, 7f); p.lineTo(17f, 10.5f)
                c.drawPath(p, s)
            }
            Icon.HIGHLIGHTER -> {
                p.moveTo(7.5f, 12.5f); p.lineTo(14f, 6f); p.lineTo(18f, 10f); p.lineTo(11.5f, 16.5f); p.close()
                p.moveTo(7.5f, 12.5f); p.lineTo(5.5f, 16.5f); p.lineTo(7.5f, 18.5f); p.lineTo(11.5f, 16.5f)
                c.drawPath(p, s)
                val w = s.strokeWidth
                s.strokeWidth = 2.6f
                c.drawLine(13f, 20.5f, 20f, 20.5f, s)
                s.strokeWidth = w
            }
            Icon.LASER -> {
                c.drawCircle(12f, 12f, 3.2f, f)
                c.drawLine(12f, 3f, 12f, 6.5f, s); c.drawLine(12f, 17.5f, 12f, 21f, s)
                c.drawLine(3f, 12f, 6.5f, 12f, s); c.drawLine(17.5f, 12f, 21f, 12f, s)
                c.drawLine(5.6f, 5.6f, 7.6f, 7.6f, s); c.drawLine(16.4f, 16.4f, 18.4f, 18.4f, s)
                c.drawLine(18.4f, 5.6f, 16.4f, 7.6f, s); c.drawLine(7.6f, 16.4f, 5.6f, 18.4f, s)
            }
            Icon.ERASER -> {
                p.moveTo(9f, 20f); p.lineTo(4.5f, 15.5f); p.lineTo(14f, 6f); p.lineTo(20f, 12f); p.lineTo(12f, 20f); p.close()
                p.moveTo(9.25f, 10.75f); p.lineTo(15.25f, 16.75f)
                p.moveTo(12f, 20f); p.lineTo(20f, 20f)
                c.drawPath(p, s)
            }
            Icon.UNDO -> {
                p.moveTo(8f, 5f); p.lineTo(4f, 9f); p.lineTo(8f, 13f)
                p.moveTo(4f, 9f); p.lineTo(14f, 9f)
                p.cubicTo(17.5f, 9f, 20f, 11.5f, 20f, 14.5f)
                p.cubicTo(20f, 17.5f, 17.5f, 20f, 14f, 20f); p.lineTo(10f, 20f)
                c.drawPath(p, s)
            }
            Icon.CLEAR -> {
                p.moveTo(5f, 7f); p.lineTo(19f, 7f)
                p.moveTo(10f, 7f); p.lineTo(10f, 4.5f); p.lineTo(14f, 4.5f); p.lineTo(14f, 7f)
                p.moveTo(6.5f, 7f); p.lineTo(7.5f, 20f); p.lineTo(16.5f, 20f); p.lineTo(17.5f, 7f)
                p.moveTo(10f, 11f); p.lineTo(10f, 16f); p.moveTo(14f, 11f); p.lineTo(14f, 16f)
                c.drawPath(p, s)
            }
        }
    }
}

/** Trims [s] with "…" so it fits in [maxWidth]. */
private fun fit(s: String, paint: Paint, maxWidth: Float): String {
    if (paint.measureText(s) <= maxWidth) return s
    var end = s.length
    while (end > 1 && paint.measureText(s, 0, end) + paint.measureText("…") > maxWidth) end--
    return s.substring(0, end) + "…"
}
