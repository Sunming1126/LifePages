import 'package:flutter/foundation.dart';

/// The photo channel currently exists only on iOS.
/// Keep non-Android behavior unchanged while Android integration is staged.
bool get supportsNativePhotos =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.android;

/// Both mobile platforms implement the book-printing channel.
bool get supportsNativeBookExport => true;
