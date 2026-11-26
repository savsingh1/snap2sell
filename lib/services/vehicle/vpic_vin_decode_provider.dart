library;

/// Live [VinDecodeProvider] backed by the NHTSA vPIC API (Valuation
/// Phase 0) — US government, free, no API key (design §2.2, VERIFIED).
///
/// vPIC decodes from manufacturer filings for the US market: Canadian
/// VINs usually decode year/make/model, but trim and equipment can be
/// incomplete. It is an IDENTITY normalizer only — never a valuation
/// source, and the result is labelled 'NHTSA vPIC' so the report can
/// say exactly where the identity came from.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../real_estate/providers.dart';
import 'vehicle_models.dart';
import 'vehicle_providers.dart';

class NhtsaVpicVinDecodeProvider implements VinDecodeProvider {
  const NhtsaVpicVinDecodeProvider({http.Client? client, Uri? baseUri})
      : _client = client,
        _baseUri = baseUri;

  final http.Client? _client;
  final Uri? _baseUri;

  static final Uri _defaultBase =
      Uri.https('vpic.nhtsa.dot.gov', '/api/vehicles/DecodeVinValues');

  @override
  String get name => 'VIN decode (NHTSA vPIC)';

  @override
  Future<ProviderResult<VehicleIdentity>> decodeVin(String vin) async {
    final normalized = vin.trim().toUpperCase();
    if (normalized.length < 11) {
      return ProviderResult.unavailable(
        providerName: name,
        unavailableReason:
            'That VIN is too short to decode (11–17 characters expected).',
        whatWouldMakeItLive: 'the full VIN from the vehicle\'s VIN plate, '
            'door sticker or registration.',
      );
    }
    final uri = (_baseUri ?? _defaultBase)
        .replace(path: '${(_baseUri ?? _defaultBase).path}/$normalized')
        .replace(queryParameters: {'format': 'json'});
    try {
      final response = await (_client ?? http.Client())
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        return _unavailable(
            'The NHTSA vPIC service returned HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _unavailable('The NHTSA vPIC service returned an unreadable response.');
      }
      final results = decoded['Results'];
      if (results is! List || results.isEmpty || results.first is! Map) {
        return _unavailable('NHTSA vPIC returned no decode for this VIN.');
      }
      final identity =
          identityFromVpicResult((results.first as Map).cast<String, dynamic>());
      if (identity == null) {
        return _unavailable(
            'NHTSA vPIC could not identify this VIN (no year, make or model on record).');
      }
      return ProviderResult.available(providerName: name, data: identity);
    } on TimeoutException {
      return _unavailable('The NHTSA vPIC service did not answer in time.');
    } catch (_) {
      return _unavailable('The NHTSA vPIC service could not be reached.');
    }
  }

  ProviderResult<VehicleIdentity> _unavailable(String reason) =>
      ProviderResult.unavailable(
        providerName: name,
        unavailableReason: reason,
        whatWouldMakeItLive:
            'the free NHTSA vPIC service being reachable, or a paid VIN decode in a later phase.',
      );

  /// Maps one vPIC `DecodeVinValues` result row to a [VehicleIdentity].
  /// Returns null when the row carries no usable identity at all.
  static VehicleIdentity? identityFromVpicResult(Map<String, dynamic> r) {
    String? text(String key) {
      final v = r[key]?.toString().trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    final year = int.tryParse(r['ModelYear']?.toString() ?? '');
    final make = text('Make');
    final model = text('Model');
    if (year == null && make == null && model == null) return null;

    // Engine: vPIC's EngineModel when present, else compose the
    // displacement/cylinder facts it did return. Nothing invented.
    var engine = text('EngineModel');
    if (engine == null) {
      final displacement = text('DisplacementL');
      final cylinders = text('EngineCylinders');
      final parts = [
        if (displacement != null) '${displacement}L',
        if (cylinders != null) '$cylinders-cylinder',
      ];
      if (parts.isNotEmpty) engine = parts.join(' ');
    }

    return VehicleIdentity(
      year: year,
      make: make,
      model: model,
      trim: text('Trim'),
      bodyStyle: text('BodyClass'),
      engine: engine,
      drivetrain: text('DriveType'),
      sourceLabel: 'NHTSA vPIC',
    );
  }
}
