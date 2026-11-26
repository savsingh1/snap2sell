// Store billing plumbing tests.
//
// Everything runs against a fake BillingStoreGateway — no real store
// calls ever happen in tests. The two behaviours that matter most:
// (1) with no product ids configured, the gateway is never touched at
// all; (2) purchases are recorded as owned but UNVERIFIED while the
// placeholder verifier is in place.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:snap2sell/services/billing_config.dart';
import 'package:snap2sell/services/billing_service.dart';

class FakeBillingGateway implements BillingStoreGateway {
  bool available = true;
  List<StoreProduct> catalogProducts = const [];
  List<String> catalogNotFound = const [];
  Object? queryError;
  bool buyResult = true;

  int isAvailableCalls = 0;
  int queryCalls = 0;
  int buyCalls = 0;
  int restoreCalls = 0;
  int completeCalls = 0;
  bool updatesListened = false;
  StoreProduct? lastBought;

  final StreamController<List<StorePurchase>> _controller =
      StreamController<List<StorePurchase>>.broadcast();

  int get totalCalls =>
      isAvailableCalls + queryCalls + buyCalls + restoreCalls + completeCalls;

  @override
  Future<bool> isAvailable() async {
    isAvailableCalls++;
    return available;
  }

  @override
  Stream<List<StorePurchase>> get purchaseUpdates {
    updatesListened = true;
    return _controller.stream;
  }

  @override
  Future<StoreProductCatalog> queryProducts(
    List<BillingProductConfig> configs,
  ) async {
    queryCalls++;
    final error = queryError;
    if (error != null) throw error;
    return StoreProductCatalog(
      products: catalogProducts,
      notFoundIds: catalogNotFound,
    );
  }

  @override
  Future<bool> buy(StoreProduct product) async {
    buyCalls++;
    lastBought = product;
    return buyResult;
  }

  @override
  Future<void> restorePurchases() async {
    restoreCalls++;
  }

  @override
  Future<void> completePurchase(StorePurchase purchase) async {
    completeCalls++;
  }

  void emit(List<StorePurchase> purchases) => _controller.add(purchases);
}

class VerifyingVerifier implements PurchaseVerifier {
  @override
  Future<PurchaseVerification> verify(StorePurchase purchase) async =>
      const PurchaseVerification.verified();
}

StoreProduct product(String id, BillingProductKind kind) => StoreProduct(
      id: id,
      kind: kind,
      title: 'Store title for $id',
      description: 'Store description for $id',
      price: '\$1.00',
      currencyCode: 'USD',
    );

void main() {
  group('parseBillingProductIds', () {
    test('empty and blank input parses to no products', () {
      expect(parseBillingProductIds(''), isEmpty);
      expect(parseBillingProductIds('   '), isEmpty);
      expect(parseBillingProductIds(',,,'), isEmpty);
    });

    test('a bare id defaults to nonConsumable', () {
      expect(
        parseBillingProductIds('premium'),
        [const BillingProductConfig(id: 'premium', kind: BillingProductKind.nonConsumable)],
      );
    });

    test('kind suffixes are parsed for every kind', () {
      expect(
        parseBillingProductIds('a:subscription,b:consumable,c:nonConsumable'),
        [
          const BillingProductConfig(id: 'a', kind: BillingProductKind.subscription),
          const BillingProductConfig(id: 'b', kind: BillingProductKind.consumable),
          const BillingProductConfig(id: 'c', kind: BillingProductKind.nonConsumable),
        ],
      );
    });

    test('whitespace around entries, ids, and kinds is trimmed', () {
      expect(
        parseBillingProductIds('  a : subscription ,  b  '),
        [
          const BillingProductConfig(id: 'a', kind: BillingProductKind.subscription),
          const BillingProductConfig(id: 'b', kind: BillingProductKind.nonConsumable),
        ],
      );
    });

    test('an unrecognised kind suffix falls back to nonConsumable', () {
      expect(
        parseBillingProductIds('a:bogus'),
        [const BillingProductConfig(id: 'a', kind: BillingProductKind.nonConsumable)],
      );
    });

    test('duplicate ids keep the first occurrence', () {
      expect(
        parseBillingProductIds('a,a:subscription'),
        [const BillingProductConfig(id: 'a', kind: BillingProductKind.nonConsumable)],
      );
    });

    test('entries with an empty id are skipped', () {
      expect(parseBillingProductIds(':subscription'), isEmpty);
    });
  });

  group('BillingService with no products configured', () {
    late FakeBillingGateway gateway;
    late BillingService service;

    setUp(() {
      gateway = FakeBillingGateway();
      service = BillingService(products: const [], gateway: gateway);
    });

    test('is not configured and settles into notConfigured', () async {
      expect(service.isConfigured, isFalse);
      expect(service.state, BillingServiceState.notConfigured);
      await service.initialise();
      expect(service.state, BillingServiceState.notConfigured);
    });

    test('initialise never touches the gateway', () async {
      await service.initialise();
      expect(gateway.totalCalls, 0);
      expect(gateway.updatesListened, isFalse);
    });

    test('buy and restore are no-ops that never touch the gateway', () async {
      await service.initialise();
      expect(await service.buy('anything'), isFalse);
      await service.restorePurchases();
      expect(gateway.totalCalls, 0);
      expect(gateway.updatesListened, isFalse);
    });

    test('reports no entitlement of either trust level', () {
      expect(service.hasEntitlement, isFalse);
      expect(service.hasVerifiedEntitlement, isFalse);
      expect(service.ownedProductIds, isEmpty);
    });

    test('fromAppConfig with no dart-define is inert and never builds '
        'the real gateway', () async {
      // Regression guard: constructing the real gateway starts a store
      // connection inside the plugin, so an unconfigured production
      // service must settle into notConfigured without ever building
      // it. If it did build it, this test environment (no store
      // channels) would surface channel errors.
      final prodService = BillingService.fromAppConfig();
      expect(prodService.isConfigured, isFalse);
      await prodService.initialise();
      expect(prodService.state, BillingServiceState.notConfigured);
      prodService.dispose();
    });
  });

  group('BillingService configured', () {
    late FakeBillingGateway gateway;
    late BillingService service;

    const monthly = BillingProductConfig(
      id: 'premium_monthly',
      kind: BillingProductKind.subscription,
    );
    const lifetime = BillingProductConfig(
      id: 'premium_lifetime',
      kind: BillingProductKind.nonConsumable,
    );

    setUp(() {
      gateway = FakeBillingGateway();
      gateway.catalogProducts = [
        product('premium_monthly', BillingProductKind.subscription),
        product('premium_lifetime', BillingProductKind.nonConsumable),
      ];
      service = BillingService(
        products: const [monthly, lifetime],
        gateway: gateway,
      );
    });

    test('initialise loads products and becomes ready', () async {
      await service.initialise();
      expect(service.state, BillingServiceState.ready);
      expect(gateway.isAvailableCalls, 1);
      expect(gateway.queryCalls, 1);
      expect(service.products.map((p) => p.id),
          ['premium_monthly', 'premium_lifetime']);
      expect(service.notFoundProductIds, isEmpty);
    });

    test('initialise is idempotent while ready', () async {
      await service.initialise();
      await service.initialise();
      expect(gateway.queryCalls, 1);
    });

    test('not-found ids from the store are surfaced', () async {
      gateway.catalogNotFound = ['ghost_product'];
      await service.initialise();
      expect(service.notFoundProductIds, ['ghost_product']);
    });

    test('unavailable store settles into storeUnavailable, no query',
        () async {
      gateway.available = false;
      await service.initialise();
      expect(service.state, BillingServiceState.storeUnavailable);
      expect(gateway.queryCalls, 0);
    });

    test('a failing product query settles into error with a message',
        () async {
      gateway.queryError = StateError('boom');
      await service.initialise();
      expect(service.state, BillingServiceState.error);
      expect(service.lastError, isNotNull);
    });

    test('buy starts the store flow for a known product', () async {
      await service.initialise();
      expect(await service.buy('premium_monthly'), isTrue);
      expect(gateway.buyCalls, 1);
      expect(gateway.lastBought?.id, 'premium_monthly');
    });

    test('buy refuses unknown products and non-ready states', () async {
      expect(await service.buy('premium_monthly'), isFalse);
      await service.initialise();
      expect(await service.buy('nope'), isFalse);
      expect(gateway.buyCalls, 0);
    });

    test('a purchased update records ownership, unverified by default',
        () async {
      await service.initialise();
      gateway.emit(const [
        StorePurchase(
          productId: 'premium_monthly',
          status: StorePurchaseStatus.pending,
          purchaseId: 'order-1',
        ),
      ]);
      await pumpEventQueue();
      expect(service.pendingProductId, 'premium_monthly');

      gateway.emit(const [
        StorePurchase(
          productId: 'premium_monthly',
          status: StorePurchaseStatus.purchased,
          purchaseId: 'order-1',
          verificationData: 'store-token',
          pendingComplete: true,
        ),
      ]);
      await pumpEventQueue();
      expect(service.pendingProductId, isNull);
      expect(service.isOwned('premium_monthly'), isTrue);
      expect(service.hasEntitlement, isTrue);
      // The placeholder verifier verifies nothing — by design.
      expect(service.hasVerifiedEntitlement, isFalse);
      // Store bookkeeping still completes so Play does not auto-refund.
      expect(gateway.completeCalls, 1);
    });

    test('an error update surfaces the store message and clears pending',
        () async {
      await service.initialise();
      gateway.emit(const [
        StorePurchase(
          productId: 'premium_monthly',
          status: StorePurchaseStatus.pending,
          purchaseId: 'order-2',
        ),
        StorePurchase(
          productId: 'premium_monthly',
          status: StorePurchaseStatus.error,
          purchaseId: 'order-2',
          errorMessage: 'Card declined by the store.',
        ),
      ]);
      await pumpEventQueue();
      expect(service.pendingProductId, isNull);
      expect(service.lastError, 'Card declined by the store.');
      expect(service.hasEntitlement, isFalse);
    });

    test('a canceled update clears pending without an error', () async {
      await service.initialise();
      gateway.emit(const [
        StorePurchase(
          productId: 'premium_lifetime',
          status: StorePurchaseStatus.pending,
          purchaseId: 'order-3',
        ),
        StorePurchase(
          productId: 'premium_lifetime',
          status: StorePurchaseStatus.canceled,
          purchaseId: 'order-3',
        ),
      ]);
      await pumpEventQueue();
      expect(service.pendingProductId, isNull);
      expect(service.lastError, isNull);
      expect(service.hasEntitlement, isFalse);
    });

    test('restore asks the store and restored purchases record ownership',
        () async {
      await service.initialise();
      await service.restorePurchases();
      expect(gateway.restoreCalls, 1);
      gateway.emit(const [
        StorePurchase(
          productId: 'premium_lifetime',
          status: StorePurchaseStatus.restored,
          purchaseId: 'order-0',
          verificationData: 'store-token',
        ),
      ]);
      await pumpEventQueue();
      expect(service.isOwned('premium_lifetime'), isTrue);
      expect(service.hasVerifiedEntitlement, isFalse);
    });

    test('a real verifier promotes ownership to verified entitlement',
        () async {
      final verifiedService = BillingService(
        products: const [monthly],
        gateway: gateway,
        verifier: VerifyingVerifier(),
      );
      await verifiedService.initialise();
      gateway.emit(const [
        StorePurchase(
          productId: 'premium_monthly',
          status: StorePurchaseStatus.purchased,
          purchaseId: 'order-9',
          verificationData: 'store-token',
        ),
      ]);
      await pumpEventQueue();
      expect(verifiedService.hasEntitlement, isTrue);
      expect(verifiedService.hasVerifiedEntitlement, isTrue);
      verifiedService.dispose();
    });
  });
}
