// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:camera_stream_ocr/app.dart';

void main() {
  testWidgets('App renders no-camera screen', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const App(cameras: []));

    // With an empty cameras list the no-camera screen should be shown.
    expect(find.text('No camera found on this device.'), findsOneWidget);
  });
}
