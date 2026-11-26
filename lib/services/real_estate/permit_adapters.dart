library;

/// Live municipal permit adapters (Valuation Phase 0) behind the existing
/// [PermitProvider] interface.
///
/// Two municipalities have verified, keyless, $0 open-data sources:
///
/// - **Vancouver** — the "Issued building permits" dataset on the City of
///   Vancouver Open Data Portal (Opendatasoft Explore API v2.1), updated
///   daily, permits issued since 2017, Open Government Licence –
///   Vancouver. The dataset is a snapshot AT ISSUANCE: it proves a permit
///   was issued for the described work; it does not show the permit's
///   current status or whether the work was completed.
/// - **Surrey** — the building-permit list published in the City of
///   Surrey's ArcGIS Hub open-data catalogue. The adapter resolves the
///   dataset's feature service through the public ArcGIS sharing API and
///   discovers the layer's fields at runtime, because the design phase
///   verified the dataset's existence but not its exact field names.
///
/// Every other municipality — including Chilliwack, whose catalogue
/// dataset fields are not yet verified — returns the honest
/// [ProviderResult.unavailable] state via [MunicipalPermitProvider].
/// No permit is ever fabricated: HTTP failures, parse failures and
/// unsupported cities are unavailable states, and a successful query with
/// no matches is an available EMPTY list (which, per the design, proves
/// nothing about whether work was done).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'property_models.dart';
import 'providers.dart';

/// Extracts the civic (house) number from a street line, if present.
String? civicNumberOf(String street) {
  // Unit-prefixed forms: "12-12165 75 Ave" or "#12 12165 75 Avenue" —
  // the civic number is the second number.
  final unitPrefixed =
      RegExp(r'^\s*#?\s*\d+\s*-\s*(\d{1,6})\b').firstMatch(street) ??
          RegExp(r'^\s*#\s*\d+\s+(\d{1,6})\b').firstMatch(street);
  if (unitPrefixed != null) return unitPrefixed.group(1);
  return RegExp(r'^\s*(\d{1,6})\b').firstMatch(street)?.group(1);
}

/// The first alphabetic street-name word ("Main" from "1234 Main Street"),
/// upper-cased — the token open-data address fields are matched against.
String? streetNameTokenOf(String street) {
  final words = street
      .replaceAll(RegExp(r'[#.,]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  for (final w in words) {
    if (RegExp(r'^[A-Za-z]{2,}$').hasMatch(w)) return w.toUpperCase();
  }
  return null;
}

/// Normalizes an open-data date value (ISO string or ArcGIS epoch
/// milliseconds) to a yyyy-mm-dd string, or null when unusable.
String? normalizePermitDate(Object? raw) {
  if (raw == null) return null;
  if (raw is num) {
    final dt = DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true);
    return dt.toIso8601String().substring(0, 10);
  }
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) return s.substring(0, 10);
  final parsed = DateTime.tryParse(s);
  if (parsed != null) return parsed.toIso8601String().substring(0, 10);
  return s;
}

// ---------------------------------------------------------------------------
// Vancouver — Opendatasoft Explore API (verified fields, design §3.2)
// ---------------------------------------------------------------------------

/// Live adapter for the City of Vancouver issued-permits open dataset.
///
/// Field mapping (fields verified in the design, §3.2):
/// `permitnumber` → permitId, `typeofwork` → type (fallback
/// `permitcategory`), `issuedate` → issuedDate, `projectdescription` →
/// description (with the declared `projectvalue` appended when present).
/// The dataset contains only ISSUED permits, so status is 'Issued'.
class VancouverPermitProvider implements PermitProvider {
  VancouverPermitProvider({http.Client? client, Uri? recordsEndpoint})
      : _client = client ?? http.Client(),
        _recordsEndpoint = recordsEndpoint ?? _defaultEndpoint;

  static final Uri _defaultEndpoint = Uri.https(
    'opendata.vancouver.ca',
    '/api/explore/v2.1/catalog/datasets/issued-building-permits/records',
  );

  final http.Client _client;
  final Uri _recordsEndpoint;

  @override
  String get name => 'City of Vancouver issued permits (open data)';

  @override
  Future<ProviderResult<List<PermitRecord>>> getPermits(
      PropertyAddress address) async {
    final number = civicNumberOf(address.street);
    final streetToken = streetNameTokenOf(address.street);
    if (number == null || streetToken == null) {
      return ProviderResult.unavailable(
        providerName: name,
        unavailableReason:
            'The street address could not be matched against the Vancouver open-data address format.',
        whatWouldMakeItLive:
            'a full civic address (number and street name) as published in the City of Vancouver dataset.',
      );
    }
    final uri = _recordsEndpoint.replace(queryParameters: {
      'where': 'address like "%$number $streetToken%"',
      'order_by': 'issuedate desc',
      'limit': '100',
    });
    try {
      final response = await _client
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        return _unavailable(
            'The City of Vancouver open-data API returned HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return _unavailable(
            'The City of Vancouver open-data API returned an unreadable response.');
      }
      final results = decoded['results'];
      final permits = <PermitRecord>[];
      if (results is List) {
        for (final raw in results) {
          if (raw is! Map<String, dynamic>) continue;
          final record = permitFromVancouverRecord(raw);
          if (record != null) permits.add(record);
        }
      }
      // An empty list is an honest result: no permits in the dataset for
      // this address (which proves nothing about work done — see design).
      return ProviderResult.available(providerName: name, data: permits);
    } on TimeoutException {
      return _unavailable(
          'The City of Vancouver open-data API did not answer in time.');
    } catch (_) {
      return _unavailable(
          'The City of Vancouver open-data API could not be reached.');
    }
  }

  ProviderResult<List<PermitRecord>> _unavailable(String reason) =>
      ProviderResult.unavailable(
        providerName: name,
        unavailableReason: reason,
        whatWouldMakeItLive:
            'the City of Vancouver Open Data Portal being reachable (free, no key required).',
      );

  /// Maps one Opendatasoft record to a [PermitRecord]. Returns null when
  /// the record carries no permit number (nothing honest to show).
  static PermitRecord? permitFromVancouverRecord(Map<String, dynamic> r) {
    final id = r['permitnumber']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    final description = r['projectdescription']?.toString().trim();
    final value = r['projectvalue'];
    final buffer = StringBuffer();
    if (description != null && description.isNotEmpty) {
      buffer.write(description);
    }
    if (value is num && value > 0) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write('Declared project value: \$${value.toStringAsFixed(0)}.');
    }
    return PermitRecord(
      permitId: id,
      type: (r['typeofwork']?.toString().trim().isNotEmpty ?? false)
          ? r['typeofwork'].toString().trim()
          : (r['permitcategory']?.toString().trim().isNotEmpty ?? false)
              ? r['permitcategory'].toString().trim()
              : 'Building permit',
      municipality: 'Vancouver',
      // The dataset is issuance-only (design §3.2): every record is an
      // issued permit; completion is not shown by this source.
      status: 'Issued',
      issuedDate: normalizePermitDate(r['issuedate']),
      description: buffer.isEmpty ? null : buffer.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Surrey — ArcGIS Hub open data (dataset verified; fields discovered)
// ---------------------------------------------------------------------------

/// Live adapter for the City of Surrey building-permit list published in
/// the city's ArcGIS Hub open-data catalogue.
///
/// The design verified the dataset exists but did NOT verify its field
/// names, so this adapter discovers the feature layer's fields from its
/// REST metadata at runtime and maps them by name fragments. If the
/// service or its address field cannot be identified, the adapter returns
/// the unavailable state rather than guessing.
class SurreyPermitProvider implements PermitProvider {
  SurreyPermitProvider({
    http.Client? client,
    Uri? sharingBase,
    String datasetItemId = defaultDatasetItemId,
    int layerIndex = 0,
  })  : _client = client ?? http.Client(),
        _sharingBase = sharingBase ?? Uri.https('www.arcgis.com', ''),
        _datasetItemId = datasetItemId,
        _layerIndex = layerIndex;

  /// ArcGIS item id of Surrey's building-permit dataset in its open-data
  /// catalogue (linked from the city's Development Statistics page as the
  /// downloadable building permit list in open data).
  static const String defaultDatasetItemId = 'f3ec200f59a342e38c52248f07fe610d';

  final http.Client _client;
  final Uri _sharingBase;
  final String _datasetItemId;
  final int _layerIndex;

  String? _serviceUrl;
  _SurreyFields? _fields;

  @override
  String get name => 'City of Surrey building permits (open data)';

  @override
  Future<ProviderResult<List<PermitRecord>>> getPermits(
      PropertyAddress address) async {
    final number = civicNumberOf(address.street);
    if (number == null) {
      return _unavailable(
          'The street address has no civic number to match against the Surrey permit list.');
    }
    try {
      final serviceUrl = await _resolveServiceUrl();
      if (serviceUrl == null) {
        return _unavailable(
            'The Surrey open-data permit service could not be located in the ArcGIS catalogue.');
      }
      final fields = await _discoverFields(serviceUrl);
      if (fields == null || fields.addressField == null) {
        return _unavailable(
            'The Surrey permit layer does not expose a recognizable address field.');
      }
      final queryUri = Uri.parse('$serviceUrl/$_layerIndex/query').replace(
        queryParameters: {
          'where':
              "UPPER(${fields.addressField}) LIKE '%$number%'",
          'outFields': '*',
          if (fields.issuedDateField != null)
            'orderByFields': '${fields.issuedDateField} DESC',
          'resultRecordCount': '100',
          'f': 'json',
        },
      );
      final response = await _client
          .get(queryUri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        return _unavailable(
            'The Surrey open-data permit service returned HTTP ${response.statusCode}.');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['error'] != null) {
        return _unavailable(
            'The Surrey open-data permit service returned an unreadable response.');
      }
      final features = decoded['features'];
      final permits = <PermitRecord>[];
      if (features is List) {
        for (final feature in features) {
          if (feature is! Map<String, dynamic>) continue;
          final attributes = feature['attributes'];
          if (attributes is! Map<String, dynamic>) continue;
          // Client-side verification: the record's own address must carry
          // the civic number we asked about.
          final recordAddress =
              attributes[fields.addressField]?.toString() ?? '';
          if (!recordAddress.contains(number)) continue;
          final record = fields.toPermitRecord(attributes);
          if (record != null) permits.add(record);
        }
      }
      return ProviderResult.available(providerName: name, data: permits);
    } on TimeoutException {
      return _unavailable(
          'The Surrey open-data permit service did not answer in time.');
    } catch (_) {
      return _unavailable(
          'The Surrey open-data permit service could not be reached.');
    }
  }

  Future<String?> _resolveServiceUrl() async {
    if (_serviceUrl != null) return _serviceUrl;
    final itemUri = _sharingBase.replace(
      path: '/sharing/rest/content/items/$_datasetItemId',
      queryParameters: {'f': 'json'},
    );
    final response = await _client
        .get(itemUri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final url = decoded['url']?.toString().trim();
    if (url == null || url.isEmpty) return null;
    _serviceUrl = url.replaceAll(RegExp(r'/+$'), '');
    return _serviceUrl;
  }

  Future<_SurreyFields?> _discoverFields(String serviceUrl) async {
    if (_fields != null) return _fields;
    final layerUri = Uri.parse('$serviceUrl/$_layerIndex')
        .replace(queryParameters: {'f': 'json'});
    final response = await _client
        .get(layerUri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final rawFields = decoded['fields'];
    if (rawFields is! List) return null;
    final names = <String>[
      for (final f in rawFields)
        if (f is Map<String, dynamic> && f['name'] != null)
          f['name'].toString(),
    ];
    if (names.isEmpty) return null;
    _fields = _SurreyFields.fromFieldNames(names);
    return _fields;
  }

  ProviderResult<List<PermitRecord>> _unavailable(String reason) =>
      ProviderResult.unavailable(
        providerName: name,
        unavailableReason: reason,
        whatWouldMakeItLive:
            'the City of Surrey open-data catalogue being reachable (free, no key required).',
      );
}

/// Field-name mapping for the Surrey permit layer, discovered from its
/// REST metadata. Matching is by upper-cased name fragments, most
/// specific candidates first — the design did not verify Surrey's exact
/// field names, so nothing here assumes a single spelling.
class _SurreyFields {
  const _SurreyFields({
    this.addressField,
    this.permitIdField,
    this.typeField,
    this.statusField,
    this.issuedDateField,
    this.descriptionField,
  });

  final String? addressField;
  final String? permitIdField;
  final String? typeField;
  final String? statusField;
  final String? issuedDateField;
  final String? descriptionField;

  factory _SurreyFields.fromFieldNames(List<String> names) {
    String? pick(List<String> fragments) {
      for (final fragment in fragments) {
        for (final n in names) {
          if (n.toUpperCase().contains(fragment)) return n;
        }
      }
      return null;
    }

    return _SurreyFields(
      addressField: pick(['ADDRESS', 'ADDR']),
      permitIdField: pick(
          ['PERMITNUMBER', 'PERMIT_NUMBER', 'PERMITNUM', 'PERMIT_NO', 'PERMITID', 'PERMIT']),
      typeField: pick(['PERMITTYPE', 'TYPEOFWORK', 'WORKTYPE', 'PERMIT_TYPE', 'TYPE']),
      statusField: pick(['STATUS']),
      issuedDateField: pick(
          ['ISSUEDATE', 'ISSUE_DATE', 'ISSUED_DATE', 'DATEISSUED', 'ISSUED']),
      descriptionField: pick(
          ['PROJECTDESCRIPTION', 'DESCRIPTION', 'WORKDESCRIPTION', 'PURPOSE']),
    );
  }

  PermitRecord? toPermitRecord(Map<String, dynamic> attributes) {
    final id = permitIdField == null
        ? ''
        : attributes[permitIdField]?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    String? text(String? field) {
      if (field == null) return null;
      final v = attributes[field]?.toString().trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    return PermitRecord(
      permitId: id,
      type: text(typeField) ?? 'Building permit',
      municipality: 'Surrey',
      status: text(statusField),
      issuedDate: issuedDateField == null
          ? null
          : normalizePermitDate(attributes[issuedDateField]),
      description: text(descriptionField),
    );
  }
}

// ---------------------------------------------------------------------------
// Dispatching provider — one adapter per municipality, explicit fallback
// ---------------------------------------------------------------------------

/// Routes permit lookups to the live per-city adapter. Cities without a
/// verified adapter — including Chilliwack, whose open-data catalogue
/// fields must be verified manually before an adapter is built (design
/// §6, Phase 0 item 5) — return an explicit unavailable state naming the
/// gap. A Chilliwack adapter slots into [_adapters] exactly the way the
/// Vancouver and Surrey adapters do once its dataset is confirmed.
class MunicipalPermitProvider implements PermitProvider {
  MunicipalPermitProvider({http.Client? client, Map<String, PermitProvider>? adapters})
      : _adapters = adapters ??
            {
              'vancouver': VancouverPermitProvider(client: client),
              'surrey': SurreyPermitProvider(client: client),
            };

  final Map<String, PermitProvider> _adapters;

  /// Cities with a live adapter, for messages and tests.
  List<String> get supportedCities => _adapters.keys.toList()..sort();

  @override
  String get name => 'Municipal permit lookup (open data)';

  static String normalizeCity(String city) {
    var c = city.trim().toLowerCase();
    for (final prefix in ['city of ', 'township of ', 'district of ']) {
      if (c.startsWith(prefix)) c = c.substring(prefix.length);
    }
    return c.trim();
  }

  @override
  Future<ProviderResult<List<PermitRecord>>> getPermits(
      PropertyAddress address) async {
    final adapter = _adapters[normalizeCity(address.city)];
    if (adapter != null) return adapter.getPermits(address);
    return ProviderResult.unavailable(
      providerName: name,
      unavailableReason:
          'No open-data permit adapter for ${address.city.trim()} yet. '
          'Live adapters cover: ${supportedCities.join(', ')}. '
          'Chilliwack is pending manual verification of its open-data '
          'catalogue fields before an adapter can be built.',
      whatWouldMakeItLive:
          'a per-municipality adapter built on that city\'s verified open-data permit feed.',
    );
  }
}

/// The Phase 0 provider bundle: identical to [RealEstateProviders.defaults]
/// except permits are served by the live [MunicipalPermitProvider].
/// Every other source keeps its honest placeholder until its own phase.
RealEstateProviders realEstateProvidersPhase0({http.Client? client}) =>
    RealEstateProviders(permits: MunicipalPermitProvider(client: client));
