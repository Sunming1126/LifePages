import 'package:flutter/foundation.dart';

/// Native photo and book-printing channels currently exist only on iOS.
/// Keep non-Android behavior unchanged while Android integration is staged.
bool get supportsNativePhotos =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.android;

bool get supportsNativeBookExport =>
    kIsWeb || defaultTargetPlatform != TargetPlatform.android;
