import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Opens [url] in an ASWebAuthenticationSession and returns the callback URL (scheme [scheme]).
/// Uses Tick's own channel (scene-safe presentation anchor, see ios/Runner/TickWebAuth.swift) and falls back to flutter_web_auth_2
/// when that channel is missing. Throws PlatformException with code CANCELED when the person closes the sheet.
const _channel = MethodChannel('tick/webauth');

Future<String> webAuthenticate(String url, {String scheme = 'tick'}) async {
  try {
    final r = await _channel.invokeMethod<String>('authenticate', {'url': url, 'scheme': scheme});
    if (r == null || r.isEmpty) throw PlatformException(code: 'EUNKNOWN', message: 'empty callback');
    return r;
  } on MissingPluginException {
    return FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: scheme);
  }
}
