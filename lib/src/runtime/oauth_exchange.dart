// Copyright (c) 2026 the libtailscale Dart package authors.
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:convert';
import 'dart:io';

import '../api/config.dart';
import '../api/exceptions.dart';

/// Exchanges a Tailscale OAuth client (id + secret) for a single-use auth key.
///
/// libtailscale cannot use OAuth client secrets directly: tsnet requires
/// `AdvertiseTags` for that path and the C API has no setter for it. So the
/// library performs the two Tailscale API calls itself, before the node
/// starts:
///
/// 1. `POST /api/v2/oauth/token` (client credentials grant)
/// 2. `POST /api/v2/tailnet/{tailnet}/keys` to mint a tagged auth key
///
/// The minted key is short-lived and only needs to survive `start()`.
class TailscaleOAuthExchanger {
  /// Creates an exchanger. [apiBaseUrl] defaults to `https://api.tailscale.com`
  /// unless the credential overrides it.
  TailscaleOAuthExchanger({
    Uri? apiBaseUrl,
    HttpClient Function()? createHttpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _apiBaseUrl = apiBaseUrl,
       _createHttpClient = createHttpClient ?? HttpClient.new;

  final Uri? _apiBaseUrl;
  final HttpClient Function() _createHttpClient;

  /// Timeout per API request.
  final Duration timeout;

  /// Mints an auth key for [credential] and returns it.
  Future<String> mintAuthKey(
    OAuthClientCredential credential, {
    String description = 'libtailscale',
  }) async {
    final base = credential.apiBaseUrl ?? _apiBaseUrl ?? tailscaleApiUrl;
    final client = _createHttpClient();
    try {
      final token = await _fetchToken(client, base, credential);
      return await _createKey(client, base, token, credential, description);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _fetchToken(
    HttpClient client,
    Uri base,
    OAuthClientCredential credential,
  ) async {
    final uri = base.resolve('/api/v2/oauth/token');
    final request = await client.postUrl(uri);
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.write(
      Uri(
        queryParameters: {
          'client_id': credential.clientId,
          'client_secret': credential.clientSecret,
        },
      ).query,
    );
    final response = await request.close().timeout(timeout);
    final body = await utf8.decodeStream(response).timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw TailscaleOAuthException('token', response.statusCode, body);
    }
    final json = jsonDecode(body);
    final token = json is Map<String, Object?> ? json['access_token'] : null;
    if (token is! String || token.isEmpty) {
      throw TailscaleOAuthException(
        'token',
        response.statusCode,
        'response has no access_token',
      );
    }
    return token;
  }

  Future<String> _createKey(
    HttpClient client,
    Uri base,
    String token,
    OAuthClientCredential credential,
    String description,
  ) async {
    final uri = base.resolve('/api/v2/tailnet/${credential.tailnet}/keys');
    final request = await client.postUrl(uri);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json;
    request.write(jsonEncode(keyRequestBody(credential, description)));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decodeStream(response).timeout(timeout);
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.created) {
      throw TailscaleOAuthException('create-key', response.statusCode, body);
    }
    final json = jsonDecode(body);
    final key = json is Map<String, Object?> ? json['key'] : null;
    if (key is! String || key.isEmpty) {
      throw TailscaleOAuthException(
        'create-key',
        response.statusCode,
        'response has no key',
      );
    }
    return key;
  }

  /// The JSON body for `POST /api/v2/tailnet/{tailnet}/keys`.
  static Map<String, Object?> keyRequestBody(
    OAuthClientCredential credential,
    String description,
  ) => {
    'capabilities': {
      'devices': {
        'create': {
          'reusable': credential.reusable,
          'ephemeral': credential.ephemeral,
          'preauthorized': credential.preauthorized,
          'tags': credential.tags,
        },
      },
    },
    'expirySeconds': credential.keyExpiry.inSeconds,
    'description': description,
  };
}
