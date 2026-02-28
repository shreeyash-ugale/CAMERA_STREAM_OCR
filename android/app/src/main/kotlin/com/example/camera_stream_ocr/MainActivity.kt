package com.example.camera_stream_ocr

import io.flutter.embedding.android.FlutterActivity
import android.os.Bundle

class MainActivity : FlutterActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // Ensure window has focus for proper camera operation
    window.decorView.requestFocus()
  }
}
