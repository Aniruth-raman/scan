package com.example.lens_lite

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Android 15 forces edge-to-edge and paints its own scrim behind the
        // navigation bar. The scanner's surface is light, so the scrim reads as
        // a black band; the original shows the surface through instead.
        window.isNavigationBarContrastEnforced = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
        }
    }

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
