import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/item.dart';
import '../providers/app_state.dart';
import 'platforms_screen.dart';
import 'property_report_screen.dart';

const List<String> kCategories = [
  'Furniture',
  'Electronics',
  'Appliances',
  'Fashion',
  'Beauty & Personal Care',
  'Toys & Games',
  'Books & Media',
  'Sports & Outdoors',
  'Baby & Kids',
  'Home & Garden',
  'Real Estate',
  'Miscellaneous',
];

/// Photo-source picker shared by the photo strip and the partial-
/// identification banner. Adds the chosen photo to the current listing.
Future<void> _addPhotoFromSourceSheet(
    BuildContext context, AppState appState) async {
  final choice = await showModalBottomSheet<ImageSource>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.photo_camera_rounded, size: 28),
              title: const Text('Take a Photo',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading:
                  const Icon(Icons.photo_library_rounded, size: 28),
              title: const Text('Choose from Gallery',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              onTap: () =>
                  Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice != null && context.mounted) {
    await appState.addPhoto(choice);
  }
}

/// Step 4: review + edit the AI-generated listing before posting.
class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  late TextEditingController _title;
  late TextEditingController _price;
  late TextEditingController _priceLow;
  late TextEditingController _priceHigh;
  late TextEditingController _description;
  String _category = 'Miscellaneous';
  ItemCondition _condition = ItemCondition.good;
  bool _initialised = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialised) return;
    final item = context.read<AppState>().currentItem;
    _title = TextEditingController(text: item?.title ?? '');
    _price =
        TextEditingController(text: _money(item?.suggestedPrice ?? 0));
    _priceLow = TextEditingController(text: _money(item?.priceLow ?? 0));
    _priceHigh =
        TextEditingController(text: _money(item?.priceHigh ?? 0));
    _description = TextEditingController(text: item?.description ?? '');
    _category = item?.category ?? 'Miscellaneous';
    if (!kCategories.contains(_category)) _category = 'Miscellaneous';
    _condition = item?.condition ?? ItemCondition.good;
    _initialised = true;
  }

  String _money(double v) =>
      v == 0 ? '' : v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);

  double _parse(String s) => double.tryParse(s.replaceAll(r'$', '').trim()) ?? 0;

  @override
  void dispose() {
    _title.dispose();
    _price.dispose();
    _priceLow.dispose();
    _priceHigh.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _continue(AppState appState) async {
    appState.updateCurrentItem(
      title: _title.text.trim().isEmpty ? 'Untitled item' : _title.text.trim(),
      category: _category,
      condition: _condition,
      suggestedPrice: _parse(_price.text),
      priceLow: _parse(_priceLow.text),
      priceHigh: _parse(_priceHigh.text),
      description: _description.text.trim(),
    );
    await appState.saveCurrentItem();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlatformsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final item = appState.currentItem;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('No item to edit.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Review Listing')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (appState.analysisError != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFB74D)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    appState.analysisError!,
                    style: const TextStyle(fontSize: 13, color: Color(0xFFE65100)),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: appState.isAnalyzing
                              ? null
                              : () => appState.retryAnalysis(),
                          child: Text(appState.isAnalyzing
                              ? 'Retrying…'
                              : 'Retry analysis'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => appState.clearAnalysisError(),
                          child: const Text('Enter details manually'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Apple/Tesla patch: the product family was identified but not the
          // exact variant. The listing WAS created — this banner is guidance,
          // not a block. The user continues, adds a model photo, or edits
          // manually; nothing forces a restart of the analysis.
          if (appState.partialNotice != null &&
              appState.analysisError == null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F0FE),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF90CAF9)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    appState.partialNotice!,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF0D47A1)),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => appState.dismissPartialNotice(),
                      child: const Text('Continue listing'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            appState.dismissPartialNotice();
                            _addPhotoFromSourceSheet(context, appState);
                          },
                          child: const Text('Add model photo'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              appState.dismissPartialNotice(),
                          child: const Text('Enter details manually'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          // Workstream B: real-estate property flow. The photo was detected
          // as a residential property — offer the valuation report. This
          // banner is additive; every other category renders exactly as
          // before.
          if (item.category == 'Real Estate' &&
              appState.propertyReport != null &&
              appState.analysisError == null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFA5D6A7)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    appState.propertyReport!.nextStepMessage,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF1B5E20)),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const PropertyReportScreen(
                                    openAddressForm: true),
                              ),
                            );
                          },
                          child: const Text('Add address'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const PropertyReportScreen(),
                              ),
                            );
                          },
                          child: const Text('View property report'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _PhotoPreview(
            path: item.photoPath,
            bytes: appState.currentPhotoBytes,
          ),
          const SizedBox(height: 12),
          _PhotoStrip(appState: appState, item: item),
          const SizedBox(height: 16),
          _label('Item title'),
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.words,
            decoration:
                const InputDecoration(hintText: 'e.g. IKEA LACK Side Table'),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Category'),
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      items: [
                        for (final c in kCategories)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) =>
                          setState(() => _category = v ?? _category),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _label('Condition'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in ItemCondition.values)
                ChoiceChip(
                  label: Text(c.label),
                  selected: _condition == c,
                  onSelected: (_) => setState(() => _condition = c),
                  selectedColor: SnapColors.primary,
                  labelStyle: TextStyle(
                    color: _condition == c
                        ? Colors.white
                        : SnapColors.textDark,
                    fontWeight: FontWeight.w600,
                  ),
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: _condition == c
                          ? SnapColors.primary
                          : const Color(0xFFE4E0F2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          _PriceCard(
            price: _price,
            priceLow: _priceLow,
            priceHigh: _priceHigh,
            rangeHint: item.rangeDisplay,
          ),
          const SizedBox(height: 14),
          _label('Description'),
          TextField(
            controller: _description,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'AI-generated description — edit freely',
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () async {
              appState.updateCurrentItem(
                title: _title.text.trim(),
                category: _category,
                condition: _condition,
                suggestedPrice: _parse(_price.text),
                priceLow: _parse(_priceLow.text),
                priceHigh: _parse(_priceHigh.text),
                description: _description.text.trim(),
              );
              final current = appState.currentItem;
              if (current == null) return;
              await appState.listingService.copyToClipboard(current);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Listing copied to clipboard')),
              );
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy Listing'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => _continue(appState),
            child: const Text('Continue to Platforms'),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: SnapColors.textDark,
          ),
        ),
      );
}

/// Multi-photo strip under the main preview: the user can add up to 5 photos
/// total (camera or gallery), remove extras, drag-reorder them, and re-run
/// the AI analysis on all photos at once. The single-photo flow is untouched.
class _PhotoStrip extends StatelessWidget {
  const _PhotoStrip({required this.appState, required this.item});

  final AppState appState;
  final Item item;

  Future<void> _pickSource(BuildContext context) =>
      _addPhotoFromSourceSheet(context, appState);

  @override
  Widget build(BuildContext context) {
    final extras = appState.extraPhotoPaths;
    final total = 1 + extras.length;
    final analyzing = appState.isAnalyzing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Photos ($total of ${AppState.maxPhotosPerListing})',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: SnapColors.textDark,
              ),
            ),
            const Spacer(),
            if (extras.length > 1)
              const Text(
                'Drag to reorder',
                style:
                    TextStyle(fontSize: 12, color: SnapColors.textMuted),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 76,
          child: Row(
            children: [
              _Thumb(
                path: item.photoPath,
                bytes: appState.currentPhotoBytes,
                badge: 'Main',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ReorderableListView(
                  scrollDirection: Axis.horizontal,
                  // onReorderItem supplies an already-adjusted newIndex.
                  onReorderItem: (oldIndex, newIndex) =>
                      appState.moveExtraPhoto(oldIndex, newIndex),
                  children: [
                    for (var i = 0; i < extras.length; i++)
                      Padding(
                        key: ValueKey('extra-$i-${extras[i]}'),
                        padding: const EdgeInsets.only(right: 8),
                        child: _Thumb(
                          path: extras[i],
                          onRemove: analyzing
                              ? null
                              : () => appState.removeExtraPhotoAt(i),
                        ),
                      ),
                  ],
                ),
              ),
              if (appState.canAddMorePhotos) ...[
                const SizedBox(width: 8),
                _AddTile(
                    onTap: analyzing ? null : () => _pickSource(context)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed:
                analyzing ? null : () => appState.reanalyzeWithPhotos(),
            icon: analyzing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child:
                        CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.autorenew_rounded, size: 18),
            label: Text(analyzing
                ? 'Analyzing $total photo${total == 1 ? '' : 's'}…'
                : 'Re-analyze with $total photo${total == 1 ? '' : 's'}'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'More angles help the AI: front, back, labels, model numbers, and any damage.',
            style:
                TextStyle(fontSize: 12, color: SnapColors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.path, this.bytes, this.badge, this.onRemove});

  final String path;
  final Uint8List? bytes;
  final String? badge;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final Widget image;
    if (kIsWeb && bytes != null) {
      image = Image.memory(bytes!, fit: BoxFit.cover);
    } else if (!kIsWeb && File(path).existsSync()) {
      image = Image.file(File(path), fit: BoxFit.cover);
    } else {
      image = Container(
        color: SnapColors.primaryLight,
        child: const Icon(Icons.image_rounded,
            color: SnapColors.primary),
      );
    }
    return SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox.expand(child: image),
          ),
          if (badge != null)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (onRemove != null)
            Positioned(
              right: 2,
              top: 2,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 76,
      height: 76,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: const BorderSide(color: Color(0xFFE4E0F2)),
          padding: EdgeInsets.zero,
        ),
        child: const Icon(
          Icons.add_a_photo_rounded,
          color: SnapColors.primary,
        ),
      ),
    );
  }
}

class _PhotoPreview extends StatelessWidget {
  const _PhotoPreview({required this.path, this.bytes});
  final String path;

  /// In-memory photo bytes (web). When null on web, the placeholder shows.
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final Widget image;
    if (kIsWeb) {
      image = bytes != null
          ? Image.memory(bytes!, fit: BoxFit.cover)
          : Container(
              color: SnapColors.primaryLight,
              child: const Icon(Icons.image_rounded,
                  size: 48, color: SnapColors.primary),
            );
    } else {
      final file = File(path);
      image = file.existsSync()
          ? Image.file(file, fit: BoxFit.cover)
          : Container(
              color: SnapColors.primaryLight,
              child: const Icon(Icons.image_rounded,
                  size: 48, color: SnapColors.primary),
            );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: image,
      ),
    );
  }
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({
    required this.price,
    required this.priceLow,
    required this.priceHigh,
    required this.rangeHint,
  });

  final TextEditingController price;
  final TextEditingController priceLow;
  final TextEditingController priceHigh;
  final String rangeHint;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sell_rounded, color: SnapColors.primary),
                const SizedBox(width: 8),
                const Text(
                  'Suggested price',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const Spacer(),
                Text(
                  'AI estimate: $rangeHint',
                  style: const TextStyle(
                    color: SnapColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: price,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: SnapColors.primary,
              ),
              decoration: const InputDecoration(
                prefixText: '\$ ',
                hintText: '0',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: priceLow,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Range low',
                      prefixText: '\$ ',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: priceHigh,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Range high',
                      prefixText: '\$ ',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
