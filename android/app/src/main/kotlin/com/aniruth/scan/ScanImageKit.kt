package com.aniruth.scan

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.abs
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
 *  - quarter-turn rotation      -> Bitmap.createBitmap(Matrix)
 *  - quarter-turn rotation      -> Bitmap.createBitmap
 *  - encode                     -> Bitmap.compress (one generation, no Dart round trip)
 *  - multi-page PDF             -> JPEG DCTDecode XObjects, hand-written xref
 *  - thumbnails                 -> BitmapFactory inSampleSize (never decodes full size)
 *
 * All methods run on a single background executor so the platform thread stays
 * free, and replies are posted back to the main looper.
 */
class ScanImageKit(private val context: Context) : MethodChannel.MethodCallHandler {

    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        executor.execute {
            try {
                val value: Any? = when (call.method) {
                    "transform" -> transform(call)
                    "thumbnail" -> thumbnail(call)
                    "publishImage" -> publishImage(call)
                    "setJpegDpi" -> setJpegDpi(call)
                    "writePdf" -> writePdf(call)
                    "listShared" -> listShared()
                    "deleteShared" -> deleteShared(call)
                    "openFile" -> openFile(call)
                    else -> throw IllegalArgumentException("unknown method ${call.method}")
                }
                main.post { result.success(value) }
            } catch (t: Throwable) {
                main.post {
                    result.error(
                        if (t is StoragePermissionRequired) "storage_permission" else "scan_image_kit",
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
        // Files published to a shared collection are opened by their own URI;
        // the legacy publish path hands out a `file://` URI on API 24-28.
        val raw = if (path.startsWith("file://")) {
            Uri.parse(path).path ?: path
        } else {
            path
        }
        val uri: Uri = if (raw.startsWith("content://")) {
            Uri.parse(raw)
        } else {
            val file = File(raw)
            if (!file.exists()) throw IllegalStateException("file not found: $raw")
            FileProvider.getUriForFile(
                context,
                "${context.packageName}$FILE_PROVIDER_SUFFIX",
                file
            )
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
        return true
    }

    // ------------------------------------------------------- publishImage --

    /**
     * Publishes a finished page into the gallery album the app owns, so the
     * export is a first-class photo and any file manager can see it.
     *
     * Returns the content URI: the scan list keeps it, which is how a later
     * delete reaches exactly this file (and why the folder indexer skips it).
     */
    private fun publishImage(call: MethodCall): Map<String, Any> {
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("bytes required")
        val name = call.argument<String>("name")?.takeIf { it.isNotBlank() } ?: "Scan"
        val folder = call.argument<String>("folder")?.takeIf { it.isNotBlank() } ?: SHARED_FOLDER
        return publish(
            bytes = bytes,
            displayName = "$name.jpg",
            mime = "image/jpeg",
            folder = folder,
            collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            relativeTo = Environment.DIRECTORY_PICTURES,
            legacyDirectory = Environment.DIRECTORY_PICTURES
        )
    }

    // --------------------------------------------------------- setJpegDpi --

    /**
     * Stamps the saved page with a resolution so print and OCR tools know its
     * physical size. Lens does the same via `addExifMetaDataForProcessedImage`.
     *
     * `ExifInterface.saveAttributes` rewrites the APP1 segment only - the JPEG
     * scan data is untouched, so this is not another generation.
     */
    private fun setJpegDpi(call: MethodCall): Boolean {
        val path = call.argument<String>("path")
            ?: throw IllegalArgumentException("path required")
        val dpi = call.argument<Int>("dpi") ?: 0
        if (dpi <= 0) return false
        val exif = ExifInterface(path)
        exif.setAttribute(ExifInterface.TAG_X_RESOLUTION, dpi.toString())
        exif.setAttribute(ExifInterface.TAG_Y_RESOLUTION, dpi.toString())
        exif.setAttribute(ExifInterface.TAG_RESOLUTION_UNIT, "2") // inches
        exif.saveAttributes()
        return true
    }

    // --------------------------------------------------------- listShared --

    /**
     * Everything sitting in the app's two shared folders, including files this
     * app never wrote (dropped in over USB, or saved by another app).
     *
     * The scan list hides the entries it already owns by URI, so a file is
     * listed once whether it was captured here or copied in.
     */
    private fun listShared(): List<Map<String, Any>> {
        val items = mutableListOf<Map<String, Any>>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            items += queryCollection(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                "${Environment.DIRECTORY_PICTURES}/$SHARED_FOLDER",
                withThumb = true
            )
            items += queryCollection(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                "${Environment.DIRECTORY_DOWNLOADS}/$SHARED_FOLDER",
                withThumb = false
            )
        } else {
            items += listLegacy(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                withThumb = true
            )
            items += listLegacy(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                withThumb = false
            )
        }
        return items
    }

    private fun queryCollection(
        collection: Uri,
        folder: String,
        withThumb: Boolean
    ): List<Map<String, Any>> {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.SIZE
        )
        val out = mutableListOf<Map<String, Any>>()
        context.contentResolver.query(
            collection,
            projection,
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
            arrayOf("$folder%"),
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2) ?: ""
                if (!isScanMime(mime)) continue
                val uri = ContentUris.withAppendedId(collection, id)
                out += describe(uri, name, mime, cursor.getLong(3), cursor.getLong(4), withThumb)
            }
        }
        return out
    }

    private fun listLegacy(publicDir: File, withThumb: Boolean): List<Map<String, Any>> {
        val directory = File(publicDir, SHARED_FOLDER)
        if (!directory.isDirectory) return emptyList()
        val out = mutableListOf<Map<String, Any>>()
        directory.listFiles()?.forEach { file ->
            if (!file.isFile) return@forEach
            val mime = when (file.extension.lowercase()) {
                "pdf" -> "application/pdf"
                "jpg", "jpeg" -> "image/jpeg"
                else -> return@forEach
            }
            out += describe(
                Uri.fromFile(file),
                file.name,
                mime,
                file.lastModified() / 1000,
                file.length(),
                withThumb
            )
        }
        return out.sortedByDescending { it["modified"] as Long }
    }

    private fun isScanMime(mime: String): Boolean =
        mime == "application/pdf" || mime == "image/jpeg" || mime == "image/png"

    private fun describe(
        uri: Uri,
        name: String,
        mime: String,
        modified: Long,
        size: Long,
        withThumb: Boolean
    ): Map<String, Any> {
        val item = mutableMapOf<String, Any>(
            "uri" to uri.toString(),
            "name" to name,
            "mime" to mime,
            "modified" to modified * 1000L,
            "size" to size
        )
        if (withThumb) {
            sharedThumbnail(uri)?.let { item["thumb"] = it }
        }
        return item
    }

    /** 240 px JPEG preview for an indexed image, decoded through the resolver. */
    private fun sharedThumbnail(uri: Uri): ByteArray? = try {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val bytes = input.readBytes()
            val src = decodeOriented(bytes, THUMB_EDGE)
            try {
                encode(scaled(src, THUMB_EDGE), 70)
            } finally {
                src.recycle()
            }
        }
    } catch (_: Throwable) {
        null
    }

    // ------------------------------------------------------- deleteShared --

    /** Removes files from the shared collections, by the URIs the list handed out. */
    private fun deleteShared(call: MethodCall): Int {
        val uris = call.argument<List<String>>("uris") ?: throw IllegalArgumentException("uris required")
        var deleted = 0
        for (raw in uris) {
            val uri = Uri.parse(raw)
            val removed = context.contentResolver.delete(uri, null, null)
            if (removed > 0) {
                deleted += removed
            } else if (uri.scheme == "file") {
                // API 24-28 fallback: the indexer handed out a plain file path.
                val file = File(uri.path ?: continue)
                if (file.exists() && file.delete()) deleted++
            }
        }
        return deleted
    }

    // ----------------------------------------------------------- transform --

    /**
     * Bakes the review stage's edit: a clockwise quarter-turn rotation, in one
     * decode and one encode.
     *
     * Tones are not applied here. Google's scanner offers its own filters and
     * shadow removal before pages reach us, so re-tinting them would be a second
     * pass over pixels that are already final.
     */
    private fun transform(call: MethodCall): Map<String, Any> {
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("bytes required")
        val turns = ((call.argument<Int>("quarterTurns") ?: 0) % 4 + 4) % 4
        val quality = call.argument<Int>("quality") ?: 95

        var page = decodeOriented(bytes, MAX_DECODE_EDGE)
        try {
            if (turns != 0) {
                val matrix = Matrix().apply { postRotate(turns * 90f) }
                val rotated = Bitmap.createBitmap(
                    page, 0, 0, page.width, page.height, matrix, true
                )
                if (rotated !== page) page.recycle()
                page = rotated
            }
            return mapOf(
                "bytes" to encode(page, quality),
                "width" to page.width,
                "height" to page.height
            )
        } finally {
            page.recycle()
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
     * Full-bleed multi-page PDF sized to each page's own aspect ratio.
     *
     * The bytes go to two places: `recordPath`, the app's own copy that the
     * scan list opens, and `MediaStore.Downloads`, so the document is also
     * reachable from any file manager.
     *
     * The pages arrive as finished JPEGs, so they are embedded as `DCTDecode`
     * image XObjects rather than decoded and re-compressed: the PDF costs
     * exactly what the JPEG costs (about 1.4 MB per 12.5 MP page) and loses no
     * further generation. `android.graphics.pdf.PdfDocument` would Flate the
     * raw bitmaps instead — 6 MB per page for the same picture.
     */
    private fun writePdf(call: MethodCall): Map<String, Any> {
        val pages = call.argument<List<ByteArray>>("pages")
            ?: throw IllegalArgumentException("pages required")
        val name = call.argument<String>("name")?.takeIf { it.isNotBlank() } ?: "Scan"
        val folder = call.argument<String>("folder")?.takeIf { it.isNotBlank() } ?: SHARED_FOLDER
        val recordPath = call.argument<String>("recordPath")?.takeIf { it.isNotBlank() }
        // 0 = High: pages are embedded as they are saved, no extra generation.
        // 1 = Medium / 2 = Low re-encode, which is what makes them smaller.
        val pdfQuality = call.argument<Int>("pdfQuality") ?: 0
        // 0 keeps the page's own geometry (A4 width at 300 dpi).
        val dpi = call.argument<Int>("dpi") ?: 0
        if (pages.isEmpty()) throw IllegalArgumentException("pages must not be empty")

        val embedded = pages.map {
            when (pdfQuality) {
                1 -> reencodeJpeg(it, 75)
                2 -> reencodeJpeg(it, 50)
                else -> it
            }
        }
        val images = embedded.map { jpegInfo(it) }
        val out = ByteArrayOutputStream(embedded.sumOf { it.size } + 8192)
        val offsets = LongArray(pages.size * 3 + 3)
        var objectId = 3

        fun write(text: String) = out.write(text.toByteArray(Charsets.ISO_8859_1))

        // Header. The comment line marks the file as binary for transport tools.
        write("%PDF-1.4\n")
        out.write(byteArrayOf(0x25, 0xE2.toByte(), 0xE3.toByte(), 0xCF.toByte(), 0xD3.toByte(), 0x0A))

        // 1: catalog.
        offsets[1] = out.size().toLong()
        write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        // 2: page tree.
        val kids = (0 until pages.size).joinToString(" ") { "${3 + it * 3} 0 R" }
        offsets[2] = out.size().toLong()
        write("2 0 obj\n<< /Type /Pages /Kids [ $kids ] /Count ${pages.size} >>\nendobj\n")

        pages.forEachIndexed { index, _ ->
            val pageId = 3 + index * 3
            val contentId = pageId + 1
            val imageId = pageId + 2
            val image = images[index]

            val widthPt = if (dpi > 0) {
                (image.width * 72.0 / dpi).roundToInt().coerceAtLeast(64)
            } else {
                A4_WIDTH_PT
            }
            val heightPt = (widthPt.toFloat() * image.height / image.width)
                .roundToInt()
                .coerceAtLeast(64)

            offsets[pageId] = out.size().toLong()
            write(
                "$pageId 0 obj\n<< /Type /Page /Parent 2 0 R " +
                    "/MediaBox [0 0 $widthPt $heightPt] " +
                    "/Resources << /XObject << /Im0 $imageId 0 R >> >> " +
                    "/Contents $contentId 0 R >>\nendobj\n"
            )

            // The unit square of the image space is mapped onto the whole page.
            val content = "q $widthPt 0 0 $heightPt 0 0 cm /Im0 Do Q\n"
            offsets[contentId] = out.size().toLong()
            write(
                "$contentId 0 obj\n<< /Length ${content.length} >>\nstream\n" +
                    content + "endstream\nendobj\n"
            )

            val colorSpace =
                if (image.components == 1) "/DeviceGray" else "/DeviceRGB"
            offsets[imageId] = out.size().toLong()
            write(
                "$imageId 0 obj\n<< /Type /XObject /Subtype /Image " +
                    "/Width ${image.width} /Height ${image.height} " +
                    "/ColorSpace $colorSpace /BitsPerComponent 8 " +
                    "/Filter /DCTDecode /Length ${embedded[index].size} >>\nstream\n"
            )
            out.write(embedded[index])
            write("\nendstream\nendobj\n")
            objectId = imageId + 1
        }

        // Cross-reference table. Every entry is exactly 20 bytes.
        val xrefOffset = out.size()
        write("xref\n0 $objectId\n0000000000 65535 f \n")
        for (id in 1 until objectId) {
            write(String.format(java.util.Locale.US, "%010d 00000 n \n", offsets[id]))
        }
        write(
            "trailer\n<< /Size $objectId /Root 1 0 R >>\n" +
                "startxref\n$xrefOffset\n%%EOF\n"
        )

        return publishPdf(out.toByteArray(), name, folder, recordPath)
    }

    /**
     * Writes the app's own copy, then publishes the same bytes into a shared
     * collection, returning the content URI that identifies exactly that file.
     *
     * The scan list keeps the URI, so a later delete reaches the published copy
     * and the folder indexer knows to skip it.
     */
    private fun publishPdf(
        bytes: ByteArray,
        name: String,
        folder: String,
        recordPath: String?
    ): Map<String, Any> {
        if (recordPath != null) {
            val record = File(recordPath)
            record.parentFile?.mkdirs()
            record.writeBytes(bytes)
        }
        return publish(
            bytes = bytes,
            displayName = "$name.pdf",
            mime = "application/pdf",
            folder = folder,
            collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            relativeTo = Environment.DIRECTORY_DOWNLOADS,
            legacyDirectory = Environment.DIRECTORY_DOWNLOADS
        )
    }

    /**
     * Publishes [bytes] into [collection] under `<relativeTo>/<folder>`.
     *
     * Q and later go through MediaStore, which needs no grant; API 24-28 write
     * into the public directory and may raise [StoragePermissionRequired] so the
     * Dart side can ask for the legacy grant and retry.
     */
    private fun publish(
        bytes: ByteArray,
        displayName: String,
        mime: String,
        folder: String,
        collection: Uri,
        relativeTo: String,
        legacyDirectory: String
    ): Map<String, Any> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$relativeTo/$folder")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("$relativeTo refused $displayName")
            try {
                resolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("$relativeTo returned no stream")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            } catch (t: Throwable) {
                resolver.delete(uri, null, null)
                throw t
            }
            return mapOf(
                "uri" to uri.toString(),
                "name" to displayName,
                "location" to "$relativeTo/$folder"
            )
        }

        val directory = File(
            Environment.getExternalStoragePublicDirectory(legacyDirectory),
            folder
        )
        val file = try {
            if (!directory.exists() && !directory.mkdirs()) {
                throw IllegalStateException("could not create ${directory.path}")
            }
            uniqueFile(directory, displayName)
        } catch (_: SecurityException) {
            throw StoragePermissionRequired()
        }
        try {
            file.writeBytes(bytes)
        } catch (_: SecurityException) {
            throw StoragePermissionRequired()
        }
        return mapOf(
            "uri" to Uri.fromFile(file).toString(),
            "name" to file.name,
            "location" to "$legacyDirectory/$folder"
        )
    }

    private fun uniqueFile(directory: File, displayName: String): File {
        val stem = displayName.substringBeforeLast('.')
        val extension = displayName.substringAfterLast('.')
        var candidate = File(directory, displayName)
        var index = 2
        while (candidate.exists()) {
            candidate = File(directory, "$stem ($index).$extension")
            index++
        }
        return candidate
    }

    /** Legacy-storage grant missing on API 24-28; the Dart side asks and retries. */
    private class StoragePermissionRequired : SecurityException("storage permission required")

    private class JpegInfo(val width: Int, val height: Int, val components: Int)

    /**
     * Reads the SOF marker instead of decoding: the pixels are never needed,
     * only the frame size and whether the JPEG carries one or three channels.
     */
    private fun jpegInfo(bytes: ByteArray): JpegInfo {
        require(bytes.size > 16 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) {
            "page is not a JPEG"
        }
        var index = 2
        while (index + 9 < bytes.size) {
            if (bytes[index] != 0xFF.toByte()) {
                index++
                continue
            }
            val marker = bytes[index + 1].toInt() and 0xFF
            // Standalone markers carry no length field.
            if (marker == 0xD8 || marker == 0x01 || marker in 0xD0..0xD7) {
                index += 2
                continue
            }
            val length = ((bytes[index + 2].toInt() and 0xFF) shl 8) or
                (bytes[index + 3].toInt() and 0xFF)
            // SOF0..SOF15, excluding DHT (C4), JPG (C8) and DAC (CC).
            if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
                val height = ((bytes[index + 5].toInt() and 0xFF) shl 8) or
                    (bytes[index + 6].toInt() and 0xFF)
                val width = ((bytes[index + 7].toInt() and 0xFF) shl 8) or
                    (bytes[index + 8].toInt() and 0xFF)
                val components = bytes[index + 9].toInt() and 0xFF
                require(width > 0 && height > 0) { "JPEG has an empty frame" }
                return JpegInfo(width, height, components)
            }
            index += 2 + length
        }
        throw IllegalArgumentException("JPEG has no SOF marker")
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

    /** Re-encodes a page JPEG at [quality]; used when the PDF asks for less. */
    private fun reencodeJpeg(bytes: ByteArray, quality: Int): ByteArray {
        val bitmap = decodeOriented(bytes, MAX_DECODE_EDGE)
        return try {
            encode(bitmap, quality)
        } finally {
            bitmap.recycle()
        }
    }

    private fun encode(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)
        return out.toByteArray()
    }

    companion object {
        /** Bound on decode allocation; a 12 MP frame stays at full size here. */
        const val MAX_DECODE_EDGE = 4096

        /** Refuse to emit a page larger than this even if the quad implies it. */
        const val MAX_OUTPUT_EDGE = 4096

        const val A4_WIDTH_PT = 595

        /** The one folder the app writes to, in both Pictures and Download. */
        const val SHARED_FOLDER = "Scan"

        /** Long edge of the preview published for an indexed image. */
        const val THUMB_EDGE = 240

        /** Must match the FileProvider authority declared in AndroidManifest.xml. */
        const val FILE_PROVIDER_SUFFIX = ".scanfileprovider"
    }
}
