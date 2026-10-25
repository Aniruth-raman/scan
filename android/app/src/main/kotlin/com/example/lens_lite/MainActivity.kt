package com.example.lens_lite

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            IMAGE_CHANNEL
        ).setMethodCallHandler(LensImageKit(applicationContext))
    }

    companion object {
        const val IMAGE_CHANNEL = "lens_lite/image"
    }
}
