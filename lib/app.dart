import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'pages/server_home_page.dart';

class App extends StatelessWidget {
  const App({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LAN Video & OCR Server',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF58A6FF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161B22),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      home: cameras.isEmpty
          ? const _NoCameraScreen()
          : ServerHomePage(cameras: cameras),
    );
  }
}

class _NoCameraScreen extends StatelessWidget {
  const _NoCameraScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('No camera found on this device.')),
    );
  }
}
