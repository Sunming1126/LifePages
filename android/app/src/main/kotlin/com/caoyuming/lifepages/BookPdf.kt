package com.caoyuming.lifepages

import android.graphics.*
import android.graphics.pdf.PdfDocument
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.*
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Base64
import java.io.FileOutputStream

/** Immutable page layout shared by print preview and Save as PDF. A4, in points. */
internal class BookPdf(args: Map<*, *>) {
    val title = (args["title"] as? String)?.takeIf { it.isNotBlank() }
        ?: "${args["name"] ?: "我的"}的回忆录"
    private val pages = mutableListOf<MutableList<(Canvas) -> Unit>>()
    private var y = 48f
    private fun newPage() { pages.add(mutableListOf()); y = 48f }
    private fun room(height: Float) { if (y + height > 788f) newPage() }
    private fun text(value: String, size: Float = 14f, bold: Boolean = false) {
        if (value.isBlank()) return
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK; textSize = size
            typeface = Typeface.create("serif", if (bold) Typeface.BOLD else Typeface.NORMAL)
        }
        val layout = StaticLayout.Builder.obtain(value, 0, value.length, paint, 499)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL).setIncludePad(false)
            .setLineSpacing(5f, 1f).build()
        for (line in 0 until layout.lineCount) {
            val height = (layout.getLineBottom(line) - layout.getLineTop(line)).toFloat()
            room(height)
            val row = value.substring(layout.getLineStart(line), layout.getLineEnd(line)).trimEnd('\n', '\r')
            val baseline = y + layout.getLineBaseline(line) - layout.getLineTop(line)
            pages.last().add { canvas -> canvas.drawText(row, 48f, baseline, paint) }
            y += height
        }
        y += 12f
    }
    private fun image(encoded: String) {
        val bytes = Base64.decode(encoded, Base64.DEFAULT)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0)
        val options = BitmapFactory.Options().apply { inSampleSize = 1 }
        while (maxOf(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 1600) options.inSampleSize *= 2
        val bitmap = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options))
        val scale = minOf(499f / bitmap.width, 500f / bitmap.height)
        val width = bitmap.width * scale; val height = bitmap.height * scale
        room(height + 12f)
        val rect = RectF(48f, y, 48f + width, y + height)
        pages.last().add { canvas -> canvas.drawBitmap(bitmap, null, rect, Paint(Paint.FILTER_BITMAP_FLAG)) }
        y += height + 12f
    }
    private fun qr(chapter: Map<*, *>) {
        val url = chapter["url"] as? String ?: ""
        if (url.isEmpty()) return
        val rows = chapter["qr"] as? List<*> ?: error("Missing QR modules")
        require(rows.size in 21..177 && rows.all { it is List<*> && it.size == rows.size && it.all { v -> v is Boolean } })
        room(196f)
        val top = y; val count = rows.size; val cell = 144f / (count + 8)
        val black = Paint().apply { color = Color.BLACK; isAntiAlias = false }
        pages.last().add { canvas ->
            canvas.drawColor(Color.WHITE, PorterDuff.Mode.DST_OVER)
            for (row in 0 until count) for (col in 0 until count) {
                if ((rows[row] as List<*>)[col] == true) {
                    val left = 225.5f + (col + 4) * cell
                    val t = top + (row + 4) * cell
                    canvas.drawRect(left, t, left + cell, t + cell, black)
                }
            }
        }
        y += 150f
        text("扫码阅读本章并聆听原声", 12f)
        // A link is also printed for readers who cannot scan; never substitute it for the QR.
        text(url, 9f)
    }
    init {
        val chapters = args["chapters"] as? List<*> ?: error("Missing chapters")
        require(chapters.isNotEmpty())
        newPage(); y = 180f
        text("LIFE PAGES", 14f); text(title, 30f, true)
        text((args["author"] as? String)?.let { "$it 著" } ?: "时光有声，故事有迹", 16f)
        for (raw in chapters) {
            val chapter = raw as? Map<*, *> ?: error("Invalid chapter")
            newPage()
            text(chapter["label"] as? String ?: "", 12f)
            text(chapter["title"] as? String ?: "", 24f, true)
            val blocks = chapter["blocks"] as? List<*>
            if (blocks != null) for (rawBlock in blocks) {
                val block = rawBlock as? Map<*, *> ?: error("Invalid block")
                (block["text"] as? String)?.let { text(it) }
                (block["image"] as? String)?.let { image(it) }
            } else text(chapter["content"] as? String ?: "")
            qr(chapter)
        }
    }
    fun adapter() = object : PrintDocumentAdapter() {
        override fun onLayout(old: PrintAttributes?, attributes: PrintAttributes?, signal: CancellationSignal,
            callback: LayoutResultCallback, extras: Bundle?) {
            if (signal.isCanceled) { callback.onLayoutCancelled(); return }
            callback.onLayoutFinished(PrintDocumentInfo.Builder("$title.pdf")
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT).setPageCount(pages.size).build(), true)
        }
        override fun onWrite(ranges: Array<out PageRange>, destination: ParcelFileDescriptor,
            signal: CancellationSignal, callback: WriteResultCallback) {
            Thread {
                val document = PdfDocument()
                try {
                    val written = mutableListOf<PageRange>()
                    for ((index, commands) in pages.withIndex()) {
                        if (signal.isCanceled) { callback.onWriteCancelled(); return@Thread }
                        if (ranges.none { index in it.start..it.end }) continue
                        val page = document.startPage(PdfDocument.PageInfo.Builder(595, 842, index + 1).create())
                        page.canvas.drawColor(Color.WHITE)
                        commands.forEach { it(page.canvas) }
                        page.canvas.drawText("${index + 1}", 290f, 818f, Paint().apply { textSize = 10f })
                        document.finishPage(page)
                        written.add(PageRange(index, index))
                    }
                    FileOutputStream(destination.fileDescriptor).use { document.writeTo(it) }
                    if (signal.isCanceled) callback.onWriteCancelled()
                    else callback.onWriteFinished(written.toTypedArray())
                } catch (_: Exception) { callback.onWriteFailed("PDF 导出失败，请重试") }
                finally { document.close() }
            }.start()
        }
    }
}
