import 'config.dart';

/// Connection state of the seller's Facebook account.
///
/// There is deliberately NO state that claims a connection exists without
/// the official Facebook Login SDK having completed a real login. Meta
/// offers no Marketplace posting permission through Facebook Login — the
/// connection is used for identity and for the business (Page/Shop +
/// Catalog) route, never for automated personal Marketplace posting.
enum FacebookConnectionState {
  /// No Meta app id configured (FACEBOOK_APP_ID dart-define is empty).
  /// Facebook features are unavailable until the owner registers a Meta
  /// app — see docs/facebook-app-setup.md.
  notConfigured,

  /// A Meta app id is configured but no user is logged in (or the SDK
  /// integration has not been wired yet — see the setup doc).
  disconnected,

  /// Facebook Login completed and a token is held by the SDK layer.
  connected,
}

/// Outcome of a connect attempt. Failures always carry an honest,
/// user-readable reason — never a fake success.
class FacebookAuthResult {
  const FacebookAuthResult._(this.ok, this.message);

  factory FacebookAuthResult.success(String message) =>
      FacebookAuthResult._(true, message);

  factory FacebookAuthResult.failure(String message) =>
      FacebookAuthResult._(false, message);

  final bool ok;
  final String message;
}

/// Facebook Login integration layer.
///
/// The production implementation will wrap the official Facebook Login
/// SDK for Flutter (flutter_facebook_auth) once the owner registers a
/// Meta app and supplies its id. Until then the app ships
/// [ConfigGatedFacebookAuthService], which reports state honestly.
abstract interface class FacebookAuthService {
  /// True when a Meta app id is present in the build config.
  bool get isConfigured;

  FacebookConnectionState get state;

  /// Display name of the connected Facebook user, when connected.
  String? get connectedUserName;

  Future<FacebookAuthResult> connect();

  Future<void> disconnect();
}

/// Default [FacebookAuthService] used until the SDK layer is wired.
///
/// Behaviour is driven entirely by [AppConfig.facebookAppId]:
/// - No app id → [FacebookConnectionState.notConfigured]; connect()
///   fails with the setup explanation.
/// - App id present → [FacebookConnectionState.disconnected]; connect()
///   still fails honestly, because the SDK package is only added once a
///   real app id exists to configure it with (docs/facebook-app-setup.md,
///   final step). It NEVER reports a connected state.
class ConfigGatedFacebookAuthService implements FacebookAuthService {
  ConfigGatedFacebookAuthService({String? appId})
      : _appId = appId ?? AppConfig.facebookAppId;

  final String _appId;

  /// Message shown when no Meta app id is configured.
  static const notConfiguredMessage =
      'Facebook connection needs a Meta app setup first. The app owner '
      'has to register Snap2Sell with Meta (a one-time setup) before '
      'anyone can connect a Facebook account here.';

  /// Message shown when an app id exists but the SDK is not wired yet.
  static const sdkNotWiredMessage =
      'Facebook Login is configured but its sign-in component still '
      'needs to be switched on by the app owner. Nothing has been '
      'connected.';

  @override
  bool get isConfigured => _appId.isNotEmpty;

  @override
  FacebookConnectionState get state => isConfigured
      ? FacebookConnectionState.disconnected
      : FacebookConnectionState.notConfigured;

  @override
  String? get connectedUserName => null;

  @override
  Future<FacebookAuthResult> connect() async {
    if (!isConfigured) {
      return FacebookAuthResult.failure(notConfiguredMessage);
    }
    return FacebookAuthResult.failure(sdkNotWiredMessage);
  }

  @override
  Future<void> disconnect() async {
    // Nothing is ever connected in this implementation, so there is
    // nothing to tear down.
  }
}
