// Visual preview goldens for the main app surfaces.
//
// These exist so design changes can be eyeballed screen by screen
// (before/after a theme or polish pass) instead of guessed. They render
// at a store-screenshot size (1080x1920 @ 3x) with the real Roboto and
// Material Icons fonts loaded from the Flutter SDK when available, so
// text does not render as test-font boxes.
//
// Run / refresh with:
//   flutter test test/preview_goldens_test.dart --update-goldens
//
// A small pixel tolerance absorbs indeterminate-spinner frames and
// anti-aliasing noise; layout breaks still fail.
//
// Images are precached inside runAsync before capture: photo widgets
// load from file/memory with real async IO, which fake-async pumps
// never let finish (capturing inside runAsync itself deadlocks, since
// frames are test-driven).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:snap2sell/app_theme.dart';
import 'package:snap2sell/models/item.dart';
import 'package:snap2sell/providers/app_state.dart';
import 'package:snap2sell/screens/confirmation_screen.dart';
import 'package:snap2sell/screens/main_scaffold.dart';
import 'package:snap2sell/screens/platforms_screen.dart';
import 'package:snap2sell/screens/premium_screen.dart';
import 'package:snap2sell/screens/processing_screen.dart';
import 'package:snap2sell/screens/results_screen.dart';
import 'package:snap2sell/screens/sell_hub_screen.dart';
import 'package:snap2sell/screens/welcome_screen.dart';
import 'package:snap2sell/services/ai_service.dart';
import 'package:snap2sell/services/billing_config.dart';
import 'package:snap2sell/services/billing_service.dart';
import 'package:snap2sell/services/storage_service.dart';

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.basedir);

  static const double _tolerance = 0.02; // 2% of pixels may differ.

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final goldenBytes = await getGoldenBytes(golden);
    final result =
        await GoldenFileComparator.compareLists(imageBytes, goldenBytes);
    if (result.passed || result.diffPercent <= _tolerance) return true;
    final error = await generateFailureOutput(result, golden, basedir);
    throw FlutterError(error);
  }
}

class _FakeStorage implements StorageService {
  _FakeStorage(this._items);

  final List<Item> _items;

  @override
  Future<List<Item>> loadItems() async => List<Item>.of(_items);

  @override
  Future<void> saveItems(List<Item> items) async {}
}

/// Simulates a configured store for the premium golden. The product
/// titles/descriptions/prices here stand in for what a real store
/// listing would return at runtime — the app itself invents none of it.
class _FakeBillingGateway implements BillingStoreGateway {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<List<StorePurchase>> get purchaseUpdates =>
      const Stream<List<StorePurchase>>.empty();

  @override
  Future<StoreProductCatalog> queryProducts(
    List<BillingProductConfig> configs,
  ) async {
    const fixtures = {
      'premium_monthly': StoreProduct(
        id: 'premium_monthly',
        kind: BillingProductKind.subscription,
        title: 'Premium Monthly',
        description: 'Billed monthly through the store. '
            'Cancel anytime in your store account.',
        price: 'CA\$6.99',
        currencyCode: 'CAD',
      ),
      'premium_lifetime': StoreProduct(
        id: 'premium_lifetime',
        kind: BillingProductKind.nonConsumable,
        title: 'Premium Lifetime',
        description: 'A single store payment for this product.',
        price: 'CA\$49.99',
        currencyCode: 'CAD',
      ),
    };
    return StoreProductCatalog(
      products: [
        for (final c in configs)
          if (fixtures.containsKey(c.id)) fixtures[c.id]!,
      ],
      notFoundIds: const [],
    );
  }

  @override
  Future<bool> buy(StoreProduct product) async => false;

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<void> completePurchase(StorePurchase purchase) async {}
}

late final String _photoPath;
late final Uint8List _photoBytes;

Item _demoItem() => Item(
      id: 'demo-nike',
      photoPath: _photoPath,
      title: 'Nike Air Zoom Pegasus — Men\'s Size 10',
      category: 'Fashion',
      condition: ItemCondition.likeNew,
      priceLow: 45,
      priceHigh: 75,
      suggestedPrice: 60,
      description: 'Nike Air Zoom Pegasus running shoes, men\'s US 10. '
          'Worn twice indoors — essentially new, no wear on the soles. '
          'Super comfortable daily trainers. Selling because the fit '
          'runs narrow for me. No box.',
      status: ListingStatus.ready,
    );

Item _secondItem() => Item(
      id: 'demo-ikea',
      photoPath: _photoPath,
      title: 'IKEA LACK Side Table — White',
      category: 'Furniture',
      condition: ItemCondition.good,
      priceLow: 8,
      priceHigh: 18,
      suggestedPrice: 12,
      description: 'IKEA LACK side table in white.',
      status: ListingStatus.draft,
    );

Future<void> _loadFontFamily(String family, List<String> paths) async {
  // One FontLoader per family, all weights added before load(): creating
  // a separate loader per weight file leaves the family broken (glyphs
  // render as boxes) for styles that name the family explicitly, which
  // includes button labels and app-bar titles via the text theme.
  final loader = FontLoader(family);
  var added = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    added = true;
  }
  if (added) await loader.load();
}

Future<void> _loadFonts() async {
  final roots = <String>[
    if (Platform.environment['FLUTTER_ROOT'] != null)
      Platform.environment['FLUTTER_ROOT']!,
    '/home/hatch/flutter',
  ];
  for (final root in roots) {
    final dir = '$root/bin/cache/artifacts/material_fonts';
    if (!Directory(dir).existsSync()) continue;
    await _loadFontFamily('MaterialIcons', ['$dir/MaterialIcons-Regular.otf']);
    await _loadFontFamily('Roboto', [
      for (final weight in ['Regular', 'Medium', 'Bold', 'Black'])
        '$dir/Roboto-$weight.ttf',
    ]);
    return;
  }
}

/// Draws a simple product-photo-like scene and returns PNG bytes.
Future<Uint8List> _makePhotoBytes() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = Size(900, 675);
  final bg = Paint()..color = const Color(0xFFEFE7DA);
  canvas.drawRect(Offset.zero & size, bg);
  // Table surface.
  canvas.drawRect(
    const Rect.fromLTWH(0, 470, 900, 205),
    Paint()..color = const Color(0xFFB08D6D),
  );
  // Soft shadow under the "vase".
  canvas.drawOval(
    const Rect.fromLTWH(300, 520, 300, 42),
    Paint()..color = const Color(0x33000000),
  );
  // Terracotta vase body.
  final vase = Paint()..color = const Color(0xFFC96F4A);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(360, 210, 180, 320),
      const Radius.circular(60),
    ),
    vase,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(395, 150, 110, 80),
      const Radius.circular(24),
    ),
    vase,
  );
  // Highlight.
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(385, 240, 34, 220),
      const Radius.circular(17),
    ),
    Paint()..color = const Color(0x2EFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(900, 675);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

AppState _state(List<Item> items, {BillingService? billing}) => AppState(
      storage: _FakeStorage(items),
      aiService: MockAiService(seed: 1),
      billing: billing,
    );

Widget _app(AppState state, Widget home) {
  return ChangeNotifierProvider<AppState>.value(
    value: state,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildSnapTheme(),
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  goldenFileComparator =
      _TolerantComparator((goldenFileComparator as LocalFileComparator).basedir);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
    _photoBytes = await _makePhotoBytes();
    final dir = await Directory.systemTemp.createTemp('snap_goldens');
    _photoPath = '${dir.path}/photo.png';
    await File(_photoPath).writeAsBytes(_photoBytes);
  });

  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<void> settleShort(WidgetTester tester) async {
    // Bounded pumps (never pumpAndSettle on these screens): enough for
    // init futures and entrance animations (<= 700ms) to complete.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
  }

  /// Precaches every image the screens can show (logo asset, the demo
  /// photo as file and as memory bytes) in real time, then captures via
  /// matchesGoldenFile. Image decoding is real async IO that fake-async
  /// pumps never finish, and captureImage deadlocks inside runAsync
  /// (frames are test-driven), so decode-first-then-capture is the only
  /// reliable order.
  Future<void> shootGolden(
      WidgetTester tester, Type screenType, String name) async {
    await tester.runAsync(() async {
      final ctx = tester.element(find.byType(MaterialApp));
      await precacheImage(const AssetImage('assets/logo.png'), ctx);
      await precacheImage(FileImage(File(_photoPath)), ctx);
      await precacheImage(MemoryImage(_photoBytes), ctx);
    });
    await tester.pump();
    await expectLater(
      find.byType(screenType),
      matchesGoldenFile('test/goldens/$name'),
    );
  }

  testWidgets('preview: welcome', (tester) async {
    usePhoneSurface(tester);
    final state = _state(const [])..init();
    await tester.pumpWidget(_app(state, const WelcomeScreen()));
    await settleShort(tester);
    await shootGolden(tester, WelcomeScreen, 'welcome.png');
  });

  testWidgets('preview: home empty', (tester) async {
    usePhoneSurface(tester);
    final state = _state(const [])..init();
    await tester.pumpWidget(_app(state, const MainScaffold()));
    await settleShort(tester);
    await shootGolden(tester, MainScaffold, 'home_empty.png');
  });

  testWidgets('preview: home with items', (tester) async {
    usePhoneSurface(tester);
    final state = _state([_demoItem(), _secondItem()])..init();
    await tester.pumpWidget(_app(state, const MainScaffold()));
    await settleShort(tester);
    await shootGolden(tester, MainScaffold, 'home_items.png');
  });

  testWidgets('preview: processing', (tester) async {
    usePhoneSurface(tester);
    final state = _state(const [])..init();
    await tester.pumpWidget(_app(state, const ProcessingScreen()));
    await tester.pump();
    // The pipeline is Future.delayed-driven, so fake-async elapsing via
    // pump(Duration) walks it deterministically; the capture itself runs
    // in real time inside shootGolden without advancing the fake steps.
    final future = state.analyzePhotoBytes(_photoBytes, savedPath: _photoPath);
    await tester.pump();
    // ~950ms in: step 2 is active, progress ring at 50%.
    await tester.pump(const Duration(milliseconds: 950));
    await shootGolden(tester, ProcessingScreen, 'processing.png');
    // Drain the pipeline so no fake timers are left pending at test end.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    await future;
    await tester.pump();
  });

  testWidgets('preview: results', (tester) async {
    usePhoneSurface(tester);
    final item = _demoItem();
    final state = _state([item])..init();
    state.openItem(item);
    await tester.pumpWidget(_app(state, const ResultsScreen()));
    await settleShort(tester);
    await shootGolden(tester, ResultsScreen, 'results.png');
  });

  testWidgets('preview: platforms', (tester) async {
    usePhoneSurface(tester);
    final item = _demoItem();
    final state = _state([item])..init();
    state.openItem(item);
    await tester.pumpWidget(_app(state, const PlatformsScreen()));
    await settleShort(tester);
    await shootGolden(tester, PlatformsScreen, 'platforms.png');
  });

  testWidgets('preview: sell hub', (tester) async {
    usePhoneSurface(tester);
    final item = _demoItem();
    final state = _state([item])..init();
    state.openItem(item);
    await tester.pumpWidget(_app(state, const SellHubScreen()));
    await settleShort(tester);
    await shootGolden(tester, SellHubScreen, 'sell_hub.png');
  });

  testWidgets('preview: premium', (tester) async {
    usePhoneSurface(tester);
    // Configured billing against the fake store: this is the only way
    // the paywall surface exists (in a default build nothing leads to
    // it and the service never touches a store).
    final billing = BillingService(
      products: parseBillingProductIds(
        'premium_monthly:subscription,premium_lifetime:nonConsumable',
      ),
      gateway: _FakeBillingGateway(),
    );
    await billing.initialise();
    final state = _state(const [], billing: billing)..init();
    await tester.pumpWidget(_app(state, const PremiumScreen()));
    await settleShort(tester);
    await shootGolden(tester, PremiumScreen, 'premium.png');
  });

  testWidgets('preview: confirmation', (tester) async {
    usePhoneSurface(tester);
    final item = _demoItem();
    final state = _state([item])..init();
    state.openItem(item);
    await tester.pumpWidget(_app(state, const ConfirmationScreen()));
    await settleShort(tester);
    await shootGolden(tester, ConfirmationScreen, 'confirmation.png');
  });
}
