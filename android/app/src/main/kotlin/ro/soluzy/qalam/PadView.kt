package ro.soluzy.qalam

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import java.nio.ByteBuffer
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.tan

/**
 * The pen pad. A rectangle with the target Mac display's shape; every S Pen sample on it
 * (hover and touch, with pressure, tilt and the side button) becomes a pen frame for the Mac.
 * Fingers are ignored, so a resting palm never moves the cursor.
 */
class PadView(context: Context) : View(context) {

    /** Gets each pen frame, header bytes left blank for the link to fill. Called on the UI thread. */
    var onFrame: ((ByteArray) -> Unit)? = null

    /** Width / height of the Mac display; the pad takes this shape. */
    var aspect = 1512f / 982f // MacBook Pro 14" until the Mac says otherwise
        set(value) {
            if (value > 0 && value != field) {
                field = value
                layoutPad()
                invalidate()
            }
        }

    /** What the pen is doing, for the side panel. */
    var penState = "away"
        private set
    var lastPressure = 0f
        private set
    private var samples = 0

    /** Samples since the last call, for the samples/s readout. */
    fun takeSampleCount(): Int = samples.also { samples = 0 }

    private val density = resources.displayMetrics.density
    private val pad = RectF()
    private val start = SystemClock.uptimeMillis() * 1_000_000L
    private var lastX = -1f
    private var lastY = -1f
    private var touching = false

    private val padFill = Paint().apply { color = 0xFF141417.toInt() }
    private val padEdge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF2C2C33.toInt(); style = Paint.Style.STROKE; strokeWidth = density
    }
    private val hoverDot = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF4FD1C5.toInt(); style = Paint.Style.STROKE; strokeWidth = 1.5f * density
    }
    private val touchDot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF4FD1C5.toInt() }

    // Android sends HOVER_EXIT just before the tip touches down. Only call the pen "gone" if no
    // touch follows shortly, otherwise every tap would flash an out-of-range on the Mac.
    private val handler = Handler(Looper.getMainLooper())
    private val penGoneLater = Runnable { penGone() }

    init {
        setBackgroundColor(0xFF0B0B0D.toInt())
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // Every digitizer sample as it arrives, not one batch per display frame.
        requestUnbufferedDispatch(InputDevice.SOURCE_CLASS_POINTER)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = layoutPad()

    private fun layoutPad() {
        val m = 14 * density
        val availW = width - 2 * m
        val availH = height - 2 * m
        if (availW <= 0 || availH <= 0) return
        val w = min(availW, availH * aspect)
        val h = w / aspect
        val left = (width - w) / 2
        val top = (height - h) / 2
        pad.set(left, top, left + w, top + h)
    }

    override fun onHoverEvent(e: MotionEvent): Boolean {
        if (!isPen(e)) return false
        if (e.actionMasked == MotionEvent.ACTION_HOVER_EXIT) {
            handler.postDelayed(penGoneLater, 80)
        } else {
            handler.removeCallbacks(penGoneLater)
            emit(e, touchingNow = false, touchingBefore = false)
        }
        return true
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (!isPen(e)) return false
        handler.removeCallbacks(penGoneLater)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                requestUnbufferedDispatch(e)
                emit(e, touchingNow = true, touchingBefore = false)
            }
            MotionEvent.ACTION_UP -> emit(e, touchingNow = false, touchingBefore = true)
            MotionEvent.ACTION_CANCEL -> penGone()
            else -> emit(e, touchingNow = true, touchingBefore = true)
        }
        return true
    }

    // Side-button presses while hovering arrive here (if Samsung's Air command doesn't take them).
    override fun onGenericMotionEvent(e: MotionEvent): Boolean {
        if (!isPen(e)) return false
        val a = e.actionMasked
        if (a == MotionEvent.ACTION_BUTTON_PRESS || a == MotionEvent.ACTION_BUTTON_RELEASE) {
            emit(e, touchingNow = touching, touchingBefore = touching)
            return true
        }
        return false
    }

    /** Tells the Mac the pen has left (out of hover range, or the app is going away). */
    fun penGone() {
        val frame = newFrame(1)
        put(Wire.le(frame, Wire.HEADER + 1), lastX, lastY, 0f, 0f, 0f,
            SystemClock.uptimeMillis() * 1_000_000L, 0)
        onFrame?.invoke(frame)
        touching = false
        penState = "away"
        lastX = -1f
        invalidate()
    }

    private fun isPen(e: MotionEvent): Boolean {
        val tool = e.getToolType(0)
        return tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER
    }

    private fun newFrame(n: Int) = ByteArray(Wire.HEADER + 1 + n * Wire.SAMPLE).also { it[Wire.HEADER] = n.toByte() }

    /** One frame per MotionEvent: its historical samples (oldest first), then the current one. */
    private fun emit(e: MotionEvent, touchingNow: Boolean, touchingBefore: Boolean) {
        val n = min(e.historySize + 1, Wire.MAX_SAMPLES)
        val frame = newFrame(n)
        val b = Wire.le(frame, Wire.HEADER + 1)
        val before = flags(e, touchingBefore)
        for (h in e.historySize - (n - 1) until e.historySize) {
            put(b, e.getHistoricalX(h), e.getHistoricalY(h), e.getHistoricalPressure(h),
                e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, h),
                e.getHistoricalAxisValue(MotionEvent.AXIS_ORIENTATION, h),
                e.getHistoricalEventTimeNanos(h), before)
        }
        val now = flags(e, touchingNow)
        put(b, e.x, e.y, e.pressure, e.getAxisValue(MotionEvent.AXIS_TILT),
            e.getAxisValue(MotionEvent.AXIS_ORIENTATION), e.eventTimeNanos, now)
        onFrame?.invoke(frame)

        samples += n
        lastX = e.x
        lastY = e.y
        lastPressure = if (touchingNow) e.pressure else 0f
        touching = touchingNow
        penState = (if (touchingNow) "touch" else "hover") + (if (now and Wire.BUTTON != 0) " + button" else "")
        invalidate()
    }

    private fun flags(e: MotionEvent, touching: Boolean): Int {
        var f = Wire.IN_RANGE
        if (touching) f = f or Wire.TOUCHING
        if (e.buttonState and PEN_BUTTONS != 0) f = f or Wire.BUTTON
        if (e.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER) f = f or Wire.ERASER
        return f
    }

    private fun put(b: ByteBuffer, x: Float, y: Float, pressure: Float, tilt: Float, orientation: Float, tNs: Long, flags: Int) {
        val nx = if (pad.width() > 0) ((x - pad.left) / pad.width()).coerceIn(0f, 1f) else 0f
        val ny = if (pad.height() > 0) ((y - pad.top) / pad.height()).coerceIn(0f, 1f) else 0f
        // Android gives tilt away from vertical + the direction it leans; tablets use tilt per axis.
        val t = tan(min(tilt, 1.5f).toDouble())
        val tiltX = Math.toDegrees(atan(sin(orientation.toDouble()) * t))
        val tiltY = Math.toDegrees(atan(-cos(orientation.toDouble()) * t))
        b.putInt(((tNs - start) / 1000).toInt())
        b.putShort((nx * 65535).roundToInt().toShort())
        b.putShort((ny * 65535).roundToInt().toShort())
        b.putShort((pressure.coerceIn(0f, 1f) * 65535).roundToInt().toShort())
        b.putShort((tiltX * 100).roundToInt().toShort())
        b.putShort((tiltY * 100).roundToInt().toShort())
        b.put(flags.toByte())
        b.put(0)
    }

    override fun onDraw(canvas: Canvas) {
        val r = 14 * density
        canvas.drawRoundRect(pad, r, r, padFill)
        canvas.drawRoundRect(pad, r, r, padEdge)
        if (lastX >= 0) {
            if (touching) canvas.drawCircle(lastX, lastY, 5 * density, touchDot)
            else canvas.drawCircle(lastX, lastY, 9 * density, hoverDot)
        }
    }

    private companion object {
        // Samsung has reported the S Pen button as either of these over the years.
        const val PEN_BUTTONS = MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY
    }
}
