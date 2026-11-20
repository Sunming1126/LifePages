package com.caoyuming.lifepages

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VoiceUploads.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "life_pages/print")
            .setMethodCallHandler { call, result ->
                if (call.method != "previewBook" && call.method != "printBook") {
                    result.notImplemented()
                } else {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) result.error("invalid_book", "书稿数据不完整", null)
                    else Thread {
                        try {
                            val book = BookPdf(args)
                            runOnUiThread {
                                try {
                                    val manager = getSystemService(PRINT_SERVICE) as android.print.PrintManager
                                    val attributes = android.print.PrintAttributes.Builder()
                                        .setMediaSize(android.print.PrintAttributes.MediaSize.ISO_A4)
                                        .setColorMode(android.print.PrintAttributes.COLOR_MODE_COLOR)
                                        .setMinMargins(android.print.PrintAttributes.Margins.NO_MARGINS)
                                        .build()
                                    manager.print(book.title, book.adapter(), attributes)
                                    result.success(null)
                                } catch (_: Exception) {
                                    result.error("print_unavailable", "无法打开 PDF 预览，请重试", null)
                                }
                            }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("invalid_book", "无法生成 PDF，请检查书稿和原声二维码后重试", null) }
                        }
                    }.start()
                }
            }
    }
}
