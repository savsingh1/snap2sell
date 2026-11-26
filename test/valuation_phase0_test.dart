// Valuation Phase 0 tests: live permit adapters (Vancouver / Surrey open
// data), NHTSA vPIC VIN decode, vehicle placeholder honesty, and the
// deep-link builders.
//
// All HTTP is mocked with fixtures shaped like the real services'
// responses (Vancouver: Opendatasoft Explore v2.1 records; Surrey:
// ArcGIS sharing + feature-layer query; vPIC: DecodeVinValues). No live
// network. The honesty assertions matter as much as the mappings: a
// failure must surface as the unavailable state, never as invented data.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:snap2sell/services/deep_links.dart';
import 'package:snap2sell/services/real_estate/permit_adapters.dart';
import 'package:snap2sell/services/real_estate/property_models.dart';
import 'package:snap2sell/services/real_estate/providers.dart';
import 'package:snap2sell/services/vehicle/vehicle_models.dart';
import 'package:snap2sell/services/vehicle/vehicle_providers.dart';
import 'package:snap2sell/services/vehicle/vpic_vin_decode_provider.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Opendatasoft Explore v2.1 shape: fields inline on each result record
/// (field names per the design's verified Vancouver field list).
Map<String, dynamic> vancouverResponse() => {
      'total_count': 2,
      'results': [
        {
          'permitnumber': 'BP-2024-001234',
          'permitnumbercreateddate': '2024-01-10T00:00:00+00:00',
          'issuedate': '2024-02-01T00:00:00+00:00',
          'permitelapseddays': 22,
          'projectvalue': 85000.0,
          'typeofwork': 'Addition / Alteration',
          'projectdescription': 'Interior alterations to kitchen and bathroom.',
          'address': '1234 MAIN ST',
          'propertyuse': 'Dwelling Uses',
          'specificusecategory': 'Single Detached House',
          'permitcategory': 'Renovation',
        },
        {
          'permitnumber': 'BP-2019-005678',
          'issuedate': '2019-06-15',
          'typeofwork': 'New Construction',
          'projectdescription': 'New single detached house with garage.',
          'address': '1234 MAIN ST',
        },
      ],
    };

const surreyServiceUrl =
    'https://services.arcgis.com/TEST/arcgis/rest/services/Building_Permits/FeatureServer';

/// ArcGIS layer metadata shape (field list only — what the adapter reads).
Map<String, dynamic> surreyLayerMetadata() => {
      'name': 'Building Permits',
      'fields': [
        {'name': 'OBJECTID', 'type': 'esriFieldTypeOID'},
        {'name': 'PERMITNUMBER', 'type': 'esriFieldTypeString'},
        {'name': 'PERMITTYPE', 'type': 'esriFieldTypeString'},
        {'name': 'STATUS', 'type': 'esriFieldTypeString'},
        {'name': 'ISSUEDATE', 'type': 'esriFieldTypeDate'},
        {'name': 'ADDRESS', 'type': 'esriFieldTypeString'},
        {'name': 'DESCRIPTION', 'type': 'esriFieldTypeString'},
      ],
    };

/// ArcGIS query shape: features with an attributes map. ISSUEDATE is
/// epoch milliseconds (1735689600000 = 2025-01-01T00:00:00Z), as ArcGIS
/// date fields are returned.
Map<String, dynamic> surreyQueryResponse() => {
      'features': [
        {
          'attributes': {
            'OBJECTID': 42,
            'PERMITNUMBER': '25-105065-000-00 B7',
            'PERMITTYPE': 'New Building',
            'STATUS': 'Issued',
            'ISSUEDATE': 1735689600000,
            'ADDRESS': '13770 90 AVE',
            'DESCRIPTION': 'New single family dwelling with secondary suite',
          },
        },
        {
          // Different civic number — the client-side address check must
          // drop this record even though the (mocked) server returned it.
          'attributes': {
            'OBJECTID': 43,
            'PERMITNUMBER': '25-999999-000-00 X1',
            'PERMITTYPE': 'Alteration',
            'STATUS': 'Issued',
            'ISSUEDATE': 1735689600000,
            'ADDRESS': '99999 90 AVE',
            'DESCRIPTION': 'Unrelated record',
          },
        },
      ],
    };

/// One MockClient that plays every external service by host/path.
MockClient allServicesClient({
  int vancouverStatus = 200,
  Object? vancouverBody,
  bool surreyFails = false,
}) {
  return MockClient((request) async {
    final url = request.url;
    if (url.host == 'opendata.vancouver.ca') {
      return _json(vancouverBody ?? vancouverResponse(), vancouverStatus);
    }
    if (url.host == 'www.arcgis.com' &&
        url.path.contains('/sharing/rest/content/items/')) {
      if (surreyFails) return _json({'error': 'not found'}, 404);
      return _json({'id': 'f3ec', 'url': surreyServiceUrl});
    }
    if (url.host == 'services.arcgis.com') {
      if (url.path.endsWith('/0/query')) return _json(surreyQueryResponse());
      if (url.path.endsWith('/0')) return _json(surreyLayerMetadata());
    }
    return _json({'error': 'unexpected ${request.url}'}, 404);
  });
}

/// vPIC DecodeVinValues shape.
Map<String, dynamic> vpicResponse() => {
      'Count': 1,
      'Message': 'Results returned successfully',
      'Results': [
        {
          'Make': 'HONDA',
          'Model': 'Civic',
          'ModelYear': '2019',
          'Trim': 'LX',
          'BodyClass': 'Sedan/Saloon',
          'DriveType': 'FWD/Front-Wheel Drive',
          'EngineModel': '',
          'DisplacementL': '2.0',
          'EngineCylinders': '4',
          'FuelTypePrimary': 'Gasoline',
          'ErrorCode': '0',
        }
      ],
    };

const vancouverAddress =
    PropertyAddress(street: '1234 Main Street', city: 'Vancouver');
const surreyAddress =
    PropertyAddress(street: '13770 90 Avenue', city: 'Surrey');
const chilliwackAddress =
    PropertyAddress(street: '45678 Yale Road', city: 'Chilliwack');

void main() {
  group('address token helpers', () {
    test('civic number: plain, unit-dash and unit-hash forms', () {
      expect(civicNumberOf('1234 Main Street'), '1234');
      expect(civicNumberOf('12-12165 75 Avenue'), '12165');
      expect(civicNumberOf('#12 12165 75 Avenue'), '12165');
      expect(civicNumberOf('Main Street'), isNull);
    });

    test('street token is the first alphabetic word, upper-cased', () {
      expect(streetNameTokenOf('1234 Main Street'), 'MAIN');
      expect(streetNameTokenOf('13770 90 Avenue'), 'AVENUE');
    });
  });

  group('VancouverPermitProvider', () {
    test('maps Opendatasoft records onto PermitRecord', () async {
      final provider = VancouverPermitProvider(client: allServicesClient());
      final result = await provider.getPermits(vancouverAddress);

      expect(result.isAvailable, isTrue);
      expect(result.data, hasLength(2));
      final first = result.data!.first;
      expect(first.permitId, 'BP-2024-001234');
      expect(first.type, 'Addition / Alteration');
      expect(first.municipality, 'Vancouver');
      expect(first.status, 'Issued'); // issuance-only dataset
      expect(first.issuedDate, '2024-02-01');
      expect(first.description, contains('Interior alterations'));
      expect(first.description, contains('Declared project value'));
      final second = result.data![1];
      expect(second.issuedDate, '2019-06-15');
      expect(second.description, isNot(contains('Declared project value')));
    });

    test('queries the dataset by civic number and street name', () async {
      Uri? seen;
      final client = MockClient((request) async {
        seen = request.url;
        return _json(vancouverResponse());
      });
      await VancouverPermitProvider(client: client)
          .getPermits(vancouverAddress);
      expect(seen!.path, contains('issued-building-permits'));
      expect(seen!.queryParameters['where'], contains('1234 MAIN'));
    });

    test('empty result set is an available EMPTY list, not unavailable',
        () async {
      final provider = VancouverPermitProvider(
          client: allServicesClient(
              vancouverBody: {'total_count': 0, 'results': []}));
      final result = await provider.getPermits(vancouverAddress);
      expect(result.isAvailable, isTrue);
      expect(result.data, isEmpty);
    });

    test('HTTP failure is the unavailable state, never fabricated permits',
        () async {
      final provider = VancouverPermitProvider(
          client: allServicesClient(vancouverStatus: 500));
      final result = await provider.getPermits(vancouverAddress);
      expect(result.isAvailable, isFalse);
      expect(result.status, DataSourceStatus.placeholderFutureIntegration);
      expect(result.data, isNull);
      expect(result.unavailableReason, contains('500'));
    });
  });

  group('SurreyPermitProvider', () {
    test('resolves the service, discovers fields and maps features',
        () async {
      final provider = SurreyPermitProvider(client: allServicesClient());
      final result = await provider.getPermits(surreyAddress);

      expect(result.isAvailable, isTrue);
      // The second fixture feature has a different civic number and must
      // be filtered out client-side.
      expect(result.data, hasLength(1));
      final permit = result.data!.single;
      expect(permit.permitId, '25-105065-000-00 B7');
      expect(permit.type, 'New Building');
      expect(permit.municipality, 'Surrey');
      expect(permit.status, 'Issued');
      expect(permit.issuedDate, '2025-01-01'); // epoch ms converted
      expect(permit.description, contains('secondary suite'));
    });

    test('catalogue failure is the unavailable state', () async {
      final provider =
          SurreyPermitProvider(client: allServicesClient(surreyFails: true));
      final result = await provider.getPermits(surreyAddress);
      expect(result.isAvailable, isFalse);
      expect(result.data, isNull);
    });
  });

  group('MunicipalPermitProvider dispatch', () {
    test('routes Vancouver and Surrey to their live adapters', () async {
      final provider = MunicipalPermitProvider(client: allServicesClient());
      expect(provider.supportedCities, ['surrey', 'vancouver']);
      final van = await provider.getPermits(vancouverAddress);
      expect(van.isAvailable, isTrue);
      expect(van.providerName, contains('Vancouver'));
      final sur = await provider.getPermits(surreyAddress);
      expect(sur.isAvailable, isTrue);
      expect(sur.providerName, contains('Surrey'));
    });

    test('unsupported city is explicit — Chilliwack names the gap', () async {
      final provider = MunicipalPermitProvider(client: allServicesClient());
      final result = await provider.getPermits(chilliwackAddress);
      expect(result.isAvailable, isFalse);
      expect(result.data, isNull);
      expect(result.unavailableReason, contains('Chilliwack'));
      expect(result.unavailableReason, contains('pending'));
    });

    test('city matching tolerates "City of Surrey" style input', () async {
      final provider = MunicipalPermitProvider(client: allServicesClient());
      final result = await provider.getPermits(const PropertyAddress(
          street: '13770 90 Avenue', city: 'City of Surrey'));
      expect(result.isAvailable, isTrue);
    });

    test('Phase 0 bundle swaps ONLY the permit provider', () {
      final bundle = realEstateProvidersPhase0(client: allServicesClient());
      expect(bundle.permits, isA<MunicipalPermitProvider>());
      expect(bundle.assessment, isA<UnavailableAssessmentProvider>());
      expect(bundle.comparables, isA<UnavailableComparableSalesProvider>());
    });
  });

  group('NhtsaVpicVinDecodeProvider', () {
    test('maps a DecodeVinValues row onto VehicleIdentity', () async {
      final provider = NhtsaVpicVinDecodeProvider(
          client: MockClient((_) async => _json(vpicResponse())));
      final result = await provider.decodeVin('2hgfc2f59kh000000');

      expect(result.isAvailable, isTrue);
      final id = result.data!;
      expect(id.year, 2019);
      expect(id.make, 'HONDA');
      expect(id.model, 'Civic');
      expect(id.trim, 'LX');
      expect(id.bodyStyle, 'Sedan/Saloon');
      expect(id.drivetrain, 'FWD/Front-Wheel Drive');
      expect(id.engine, '2.0L 4-cylinder'); // composed, not invented
      expect(id.sourceLabel, 'NHTSA vPIC');
      expect(id.displayName, '2019 HONDA Civic LX');
    });

    test('a VIN vPIC cannot identify is the unavailable state', () async {
      final empty = {
        'Count': 1,
        'Results': [
          {'Make': '', 'Model': '', 'ModelYear': '', 'ErrorCode': '1'}
        ],
      };
      final provider = NhtsaVpicVinDecodeProvider(
          client: MockClient((_) async => _json(empty)));
      final result = await provider.decodeVin('1HGCM82633A004352');
      expect(result.isAvailable, isFalse);
      expect(result.data, isNull);
    });

    test('a too-short VIN is rejected without any HTTP call', () async {
      var called = false;
      final provider = NhtsaVpicVinDecodeProvider(
          client: MockClient((_) async {
        called = true;
        return _json(vpicResponse());
      }));
      final result = await provider.decodeVin('12345');
      expect(result.isAvailable, isFalse);
      expect(result.unavailableReason, contains('too short'));
      expect(called, isFalse);
    });
  });

  group('vehicle placeholder honesty', () {
    const query = VehicleQuery(
      identity: VehicleIdentity(year: 2019, make: 'Honda', model: 'Civic'),
      mileageKm: 120000,
      condition: 'good',
      postalCode: 'V2P 1A1',
    );

    test('guide value placeholder returns unavailable with a reason',
        () async {
      final result =
          await VehicleProviders.defaults.guideValue.getGuideValue(query);
      expect(result.isAvailable, isFalse);
      expect(result.status, DataSourceStatus.placeholderFutureIntegration);
      expect(result.data, isNull);
      expect(result.unavailableReason, contains('licensed'));
      expect(result.toNote().isLive, isFalse);
    });

    test('comps placeholder returns unavailable and invents no listings',
        () async {
      final result = await VehicleProviders.defaults.comps.getComps(query);
      expect(result.isAvailable, isFalse);
      expect(result.data, isNull);
      expect(result.unavailableReason, contains('Facebook Marketplace'));
    });

    test('the Phase 0 bundle wires vPIC as the live VIN decoder', () {
      expect(VehicleProviders.defaults.vinDecode,
          isA<NhtsaVpicVinDecodeProvider>());
    });
  });

  group('ValuationDeepLinks', () {
    test('BC Assessment link opens the official search', () {
      final uri = ValuationDeepLinks.bcAssessmentSearch(vancouverAddress);
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.bcassessment.ca');
    });

    test('Zealty link lands on the city region page', () {
      expect(ValuationDeepLinks.zealtySoldHistory(surreyAddress).toString(),
          'https://www.zealty.ca/region/bc/surrey');
      expect(
          ValuationDeepLinks.zealtySoldHistory(const PropertyAddress(
                  street: '1234 Marine Drive', city: 'North Vancouver'))
              .toString(),
          'https://www.zealty.ca/region/bc/north-vancouver');
    });

    test('Facebook Marketplace link is a prefilled vehicle search', () {
      final uri = ValuationDeepLinks.facebookMarketplaceVehicleSearch(
          '2019 Honda Civic');
      expect(uri.host, 'www.facebook.com');
      expect(uri.path, '/marketplace/search/');
      expect(uri.queryParameters['query'], '2019 Honda Civic');
    });
  });
}
