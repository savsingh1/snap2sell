import 'package:flutter/widgets.dart';

/// Global navigator key, kept in its own file so any screen can reset the
/// navigation stack (or open sheets/dialogs afterwards) without creating
/// import cycles back through main.dart.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
