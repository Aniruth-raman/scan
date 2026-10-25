package com.example.lens_lite

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.media.ExifInterface
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.graphics.pdf.PdfDocument
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Image work that Flutter should not be doing in Dart.
 *
 * Everything here maps onto a platform component that already exists and is
 * hardware accelerated or native-C:
 *
 *  - decode + EXIF orientation  -> BitmapFactory + ExifInterface
 *  - perspective rectification  -> Matrix.setPolyToPoly + Canvas.drawBitmap
 *  - tone presets               -> ColorMatrixColorFilter
 *  - encode                     -> Bitmap.compress (one generation, no Dart round trip)
 *  - multi-page PDF             -> android.graphics.pdf.PdfDocument
 *  - thumbnails                 -> BitmapFactory inSampleSize (never decodes full size)
 *
 * All methods run on a single background executor so the platform thread stays
 * free, and replies are posted back to the main looper.
 */
class LensImageKit(private val context: Context) : MethodChannel.MethodCallHandler {

    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val value: Any? = when (call.method) {
                    "analyze" -> analyze(call)
                    "warp" -> warp(call)
                    "thumbnail" -> thumbnail(call)
                    "writePdf" -> writePdf(call)
                    "openFile" -> openFile(call)
                    else -> throw IllegalArgumentException("unknown method ${call.method}")
                }
                main.post { result.success(value) }
            } catch (t: Throwable) {
                main.post {
                    result.error(
                        "lens_image_kit",
                        t.message ?: t.javaClass.simpleName,
                        null
                    )
                }
            }
        }
    }

    // ------------------------------------------------------------ openFile --

    /** Hands a saved scan to the system viewer via a scoped content URI. */
    private fun openFile(call: MethodCall): Boolean {
        val path = call.argument<String>("path")
            ?: throw IllegalArgumentException("path required")
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("file not found: $path")

        val uri: Uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}$FILE_PROVIDER_SUFFIX",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        return true
    }

    // ------------------------------------------------------------- analyze --

    /**
     * One decode of the capture produces both the on-screen preview and the
     * small RGBA buffer the Dart detector scans. The detector therefore never
     * touches a multi-megabyte JPEG.
     */
    private fun analyze(call: MethodCall): Map<String, Any> {
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("bytes required")
        val previewEdge = call.argument<Int>("previewEdge") ?: 1440
        val detectEdge = call.argument<Int>("detectEdge") ?: 480

        val full = decodeOriented(bytes, MAX_DECODE_EDGE)
        try {
            val preview = scaled(full, previewEdge)
            val detect = scaled(full, detectEdge)

            val pixels = IntArray(detect.width * detect.height)
            detect.getPixels(pixels, 0, detect.width, 0, 0, detect.width, detect.height)
            val rgba = ByteArray(pixels.size * 4)
            for (i in pixels.indices) {
                val p = pixels[i]
                val o = i * 4
                rgba[o] = (p shr 16 and 0xFF).toByte()
                rgba[o + 1] = (p shr 8 and 0xFF).toByte()
                rgba[o + 2] = (p and 0xFF).toByte()
                rgba[o + 3] = (p ushr 24 and 0xFF).toByte()
            }

            return mapOf(
                "preview" to encode(preview, 90),
                "previewWidth" to preview.width,
                "previewHeight" to preview.height,
                "fullWidth" to full.width,
                "fullHeight" to full.height,
                "rgba" to rgba,
                "detectWidth" to detect.width,
                "detectHeight" to detect.height
            )
        } finally {
            full.recycle()
        }
    }

    // ---------------------------------------------------------------- warp --

    /**
     * Rectifies the quad at full capture resolution.
     *
     * The output size comes from the quad's own edge lengths, so a page cropped
     * from the middle of a 12 MP frame keeps the pixels it actually had instead
     * of being resampled to a fixed bound. It is never upscaled past the source.
     */
    private fun warp(call: MethodCall): Map<String, Any> {
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("bytes required")
        val corners = call.argument<List<Double>>("corners")
            ?: throw IllegalArgumentException("corners required")
        if (corners.size != 8) throw IllegalArgumentException("corners must be 8 values")
        val filterId = call.argument<Int>("filter") ?: 0
        val quality = call.argument<Int>("quality") ?: 95

        val src = decodeOriented(bytes, MAX_DECODE_EDGE)
        try {
            // Corners arrive in full-resolution oriented coordinates.
            val sx = src.width.toDouble()
            val sy = src.height.toDouble()
            val x = DoubleArray(4) { corners[it * 2] * sx / fullWidthOf(call, src.width) }
            val y = DoubleArray(4) { corners[it * 2 + 1] * sy / fullHeightOf(call, src.height) }

            fun dist(a: Int, b: Int): Double =
                sqrt((x[a] - x[b]) * (x[a] - x[b]) + (y[a] - y[b]) * (y[a] - y[b]))

            val outW = min(
                src.width,
                max(dist(0, 1), dist(3, 2)).roundToInt()
            ).coerceIn(16, MAX_OUTPUT_EDGE)
            val outH = min(
                src.height,
                max(dist(0, 3), dist(1, 2)).roundToInt()
            ).coerceIn(16, MAX_OUTPUT_EDGE)

            val srcPts = floatArrayOf(
                x[0].toFloat(), y[0].toFloat(),
                x[1].toFloat(), y[1].toFloat(),
                x[2].toFloat(), y[2].toFloat(),
                x[3].toFloat(), y[3].toFloat()
            )
            val dstPts = floatArrayOf(
                0f, 0f,
                (outW - 1).toFloat(), 0f,
                (outW - 1).toFloat(), (outH - 1).toFloat(),
                0f, (outH - 1).toFloat()
            )

            // setPolyToPoly gives dst -> src; the canvas needs src -> dst.
            val inverse = Matrix()
            val forward = Matrix()
            if (!forward.setPolyToPoly(dstPts, 0, srcPts, 0, 4)) {
                throw IllegalStateException("degenerate quad")
            }
            if (!forward.invert(inverse)) {
                throw IllegalStateException("quad is not invertible")
            }

            val out = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG)
            filterFor(filterId)?.let { paint.colorFilter = it }
            // Crop regions can leave uncovered pixels at the border.
            canvas.drawColor(Color.WHITE)
            canvas.drawBitmap(src, inverse, paint)

            val encoded = encode(out, quality)
            val result = mapOf(
                "bytes" to encoded,
                "width" to out.width,
                "height" to out.height
            )
            out.recycle()
            return result
        } finally {
            src.recycle()
        }
    }

    // ----------------------------------------------------------- thumbnail --

    private fun thumbnail(call: MethodCall): Map<String, Any> {
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("bytes required")
        val maxEdge = call.argument<Int>("maxEdge") ?: 320
        val quality = call.argument<Int>("quality") ?: 80
        val src = decodeOriented(bytes, maxEdge * 2)
        try {
            val thumb = scaled(src, maxEdge)
            return mapOf(
                "bytes" to encode(thumb, quality),
                "width" to thumb.width,
                "height" to thumb.height
            )
        } finally {
            src.recycle()
        }
    }

    // ------------------------------------------------------------- writePdf --

    /**
     * Full-bleed multi-page PDF sized to each page's own aspect ratio, written
     * natively. No white margins, no re-layout, no extra Dart dependency.
     */
    private fun writePdf(call: MethodCall): Map<String, Any> {
        val pages = call.argument<List<ByteArray>>("pages")
            ?: throw IllegalArgumentException("pages required")
        val path = call.argument<String>("path")
            ?: throw IllegalArgumentException("path required")
        if (pages.isEmpty()) throw IllegalArgumentException("pages must not be empty")

        val document = PdfDocument()
        try {
            pages.forEachIndexed { index, pageBytes ->
                val bitmap = decodeOriented(pageBytes, MAX_DECODE_EDGE)
                try {
                    val widthPt = A4_WIDTH_PT
                    val heightPt = (A4_WIDTH_PT * bitmap.height.toFloat() / bitmap.width)
                        .roundToInt()
                        .coerceAtLeast(64)

                    val info = PdfDocument.PageInfo.Builder(
                        widthPt,
                        heightPt,
                        index + 1
                    ).create()
                    val page = document.startPage(info)
                    val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
                    paint.isFilterBitmap = true
                    page.canvas.drawBitmap(
                        bitmap,
                        null,
                        RectF(0f, 0f, widthPt.toFloat(), heightPt.toFloat()),
                        paint
                    )
                    document.finishPage(page)
                } finally {
                    bitmap.recycle()
                }
            }

            val file = File(path)
            file.parentFile?.mkdirs()
            file.outputStream().use { document.writeTo(it) }
            return mapOf("path" to path, "bytes" to file.length(), "pages" to pages.size)
        } finally {
            document.close()
        }
    }

    // -------------------------------------------------------------- helpers --

    private fun fullWidthOf(call: MethodCall, fallback: Int): Double =
        (call.argument<Int>("fullWidth") ?: fallback).toDouble()

    private fun fullHeightOf(call: MethodCall, fallback: Int): Double =
        (call.argument<Int>("fullHeight") ?: fallback).toDouble()

    /** Decodes with an inSampleSize chosen to stay under [maxEdge] before allocation. */
    private fun decodeOriented(bytes: ByteArray, maxEdge: Int): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw IllegalStateException("not a decodable image")
        }

        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / sample > maxEdge) {
            sample *= 2
        }

        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            ?: throw IllegalStateException("decode failed")

        val matrix = Matrix()
        when (readOrientation(bytes)) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
        }

        if (matrix.isIdentity) return bitmap

        val oriented = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true
        )
        if (oriented !== bitmap) bitmap.recycle()
        bitmap = oriented
        return bitmap
    }

    private fun readOrientation(bytes: ByteArray): Int = try {
        ExifInterface(ByteArrayInputStream(bytes)).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL
        )
    } catch (_: Throwable) {
        ExifInterface.ORIENTATION_NORMAL
    }

    /** Downscales so the longest edge is at most [maxEdge]; never upscales. */
    private fun scaled(source: Bitmap, maxEdge: Int): Bitmap {
        val longest = max(source.width, source.height)
        if (longest <= maxEdge) return source
        val ratio = maxEdge.toFloat() / longest
        val w = (source.width * ratio).roundToInt().coerceAtLeast(1)
        val h = (source.height * ratio).roundToInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, w, h, true)
    }

    private fun encode(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)
        return out.toByteArray()
    }

    /**
     * Tone presets. These are the same three the scanner exposes; all of them
     * are a single 4x5 colour matrix, which the GPU applies for free.
     */
    private fun filterFor(id: Int): ColorMatrixColorFilter? = when (id) {
        1 -> { // enhance: gentle contrast + saturation lift
            val matrix = ColorMatrix()
            matrix.setSaturation(1.18f)
            val contrast = ColorMatrix(
                floatArrayOf(
                    1.12f, 0f, 0f, 0f, -15f,
                    0f, 1.12f, 0f, 0f, -15f,
                    0f, 0f, 1.12f, 0f, -15f,
                    0f, 0f, 0f, 1f, 0f
                )
            )
            matrix.postConcat(contrast)
            ColorMatrixColorFilter(matrix)
        }
        2 -> { // greyscale
            val matrix = ColorMatrix()
            matrix.setSaturation(0f)
            ColorMatrixColorFilter(matrix)
        }
        3 -> { // black and white: strong contrast on a desaturated plate
            val matrix = ColorMatrix()
            matrix.setSaturation(0f)
            val contrast = ColorMatrix(
                floatArrayOf(
                    1.7f, 0f, 0f, 0f, -89.6f,
                    0f, 1.7f, 0f, 0f, -89.6f,
                    0f, 0f, 1.7f, 0f, -89.6f,
                    0f, 0f, 0f, 1f, 0f
                )
            )
            matrix.postConcat(contrast)
            ColorMatrixColorFilter(matrix)
        }
        else -> null
    }

    companion object {
        /** Bound on decode allocation; a 12 MP frame stays at full size here. */
        const val MAX_DECODE_EDGE = 4096

        /** Refuse to emit a page larger than this even if the quad implies it. */
        const val MAX_OUTPUT_EDGE = 4096

        const val A4_WIDTH_PT = 595

        /** Must match the FileProvider authority declared in AndroidManifest.xml. */
        const val FILE_PROVIDER_SUFFIX = ".lensfileprovider"
    }
}
