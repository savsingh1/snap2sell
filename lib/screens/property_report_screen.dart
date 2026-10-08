library;

/// Property value report screen (Workstream B, additive).
///
/// Consumer-first: the estimated range (or the honest insufficient-data
/// state) up top, then VIEW VALUATION DETAILS, then the optional
/// REALTOR / PROFESSIONAL MODE toggle. Every section labels its evidence —
/// nothing here is presented as a formal appraisal.
///
/// Address entry: ADD ADDRESS opens a form; the address is user-entered
/// only, never inferred from the photo. CONTINUE WITH PHOTO ANALYSIS
/// dismisses the prompt and shows the visual analysis.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../providers/app_state.dart';
import '../services/real_estate/property_models.dart';

class PropertyReportScreen extends StatefulWidget {
  const PropertyReportScreen({super.key, this.openAddressForm = false});

  /// When true, the address form opens immediately (ADD ADDRESS entry).
  final bool openAddressForm;

  @override
  State<PropertyReportScreen> createState() => _PropertyReportScreenState();
}

class _PropertyReportScreenState extends State<PropertyReportScreen> {
  bool _professionalMode = false;
  bool _detailsExpanded = false;
  bool _savingAddress = false;

  final _street = TextEditingController();
  final _city = TextEditingController();
  final _province = TextEditingController(text: 'BC');
  final _postal = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.openAddressForm) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showAddressForm());
    }
  }

  @override
  void dispose() {
    _street.dispose();
    _city.dispose();
    _province.dispose();
    _postal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final report = appState.propertyReport;
    if (report == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Property Report')),
        body: const Center(
          child: Text('No property report for this item.'),
        ),
      );
    }
    final record = report.record;
    final valuation = record.valuation;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Property Value Estimate'),
        actions: [
          // REALTOR / PROFESSIONAL MODE toggle.
          Row(
            children: [
              const Text('Pro', style: TextStyle(fontSize: 12)),
              Switch(
                value: _professionalMode,
                onChanged: (v) => setState(() => _professionalMode = v),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          _headerCard(report),
          const SizedBox(height: 12),
          _valuationCard(valuation, report),
          const SizedBox(height: 12),
          if (!report.addressConfirmed) _addressPromptCard(report),
          const SizedBox(height: 12),
          _detailsSection(report),
          if (_professionalMode) ...[
            const SizedBox(height: 12),
            _professionalSection(report),
          ],
          const SizedBox(height: 16),
          const Text(
            'This is an automated estimate for informational purposes only — '
            'not a formal appraisal. Never rely on it alone for a pricing '
            'decision.',
            style: TextStyle(
                fontSize: 12, color: SnapColors.textMuted, height: 1.4),
          ),
        ],
      ),
    );
  }

  // ----- consumer header ---------------------------------------------------

  Widget _headerCard(PropertyValuationReport report) {
    final record = report.record;
    final addressLine = record.address?.displayLine ?? 'Address not added';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              addressLine,
              style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: SnapColors.textDark),
            ),
            const SizedBox(height: 4),
            Text(
              record.propertyType.label,
              style: const TextStyle(
                  fontSize: 13, color: SnapColors.textMuted),
            ),
            if (record.address == null)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Detected from photo — address not confirmed.',
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: SnapColors.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _valuationCard(
      ValuationResult valuation, PropertyValuationReport report) {
    return Card(
      color: SnapColors.primaryLight,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: valuation.insufficientData
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Estimated Market Range',
                      style:
                          TextStyle(fontSize: 13, color: SnapColors.textMuted)),
                  const SizedBox(height: 6),
                  const Text(
                    'Insufficient data',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: SnapColors.textDark),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    report.nextStepMessage,
                    style: const TextStyle(
                        fontSize: 13, color: SnapColors.textDark, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  const Text('What is missing:',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  for (final r in valuation.reasons)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('• $r',
                          style: const TextStyle(
                              fontSize: 12,
                              color: SnapColors.textMuted,
                              height: 1.4)),
                    ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Estimated Market Range',
                      style:
                          TextStyle(fontSize: 13, color: SnapColors.textMuted)),
                  const SizedBox(height: 6),
                  Text(
                    '${_money(valuation.estimatedLow)} – ${_money(valuation.estimatedHigh)}',
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: SnapColors.textDark),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Likely market value: ${_money(valuation.estimatedMid)}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Confidence: ${_confidencePct(valuation.confidence)} '
                    '(${valuation.confidence.name.toUpperCase()})',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _addressPromptCard(PropertyValuationReport report) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              report.nextStepMessage,
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _showAddressForm,
                    child: const Text('Add address'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Continue with photo analysis'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ----- valuation details -------------------------------------------------

  Widget _detailsSection(PropertyValuationReport report) {
    final record = report.record;
    return Card(
      child: Column(
        children: [
          ListTile(
            title: const Text('View valuation details',
                style: TextStyle(fontWeight: FontWeight.w600)),
            trailing: Icon(_detailsExpanded
                ? Icons.expand_less
                : Icons.expand_more),
            onTap: () =>
                setState(() => _detailsExpanded = !_detailsExpanded),
          ),
          if (_detailsExpanded) ...[
            const Divider(height: 1),
            _detailTile('Property details',
                _propertyDetailsText(record) ?? 'Not available.'),
            _detailTile('BC Assessment', _assessmentText(record)),
            _detailTile('Permit / renovation history',
                _permitText(record)),
            _detailTile('Recent sales', _salesText(record)),
            _detailTile(
                'Comparable sales', _comparablesText(record, brief: true)),
            _detailTile('Property condition',
                _conditionText(record)),
            _detailTile('Valuation adjustments',
                _adjustmentsText(record)),
            _detailTile('Methodology', record.valuation.methodologyNote),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Data sources',
                      style:
                          TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  for (final s in report.dataSources)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            s.isLive
                                ? Icons.check_circle
                                : Icons.pause_circle_outline,
                            size: 16,
                            color: s.isLive
                                ? SnapColors.accentDark
                                : SnapColors.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.sourceName,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                                Text(s.detail,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: SnapColors.textMuted,
                                        height: 1.4)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailTile(String title, String body) {
    return ExpansionTile(
      title: Text(title, style: const TextStyle(fontSize: 14)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(body,
                style: const TextStyle(
                    fontSize: 13, color: SnapColors.textDark, height: 1.5)),
          ),
        ),
      ],
    );
  }

  // ----- professional mode -------------------------------------------------

  Widget _professionalSection(PropertyValuationReport report) {
    final record = report.record;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('REALTOR / PROFESSIONAL MODE',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: SnapColors.primary)),
            const SizedBox(height: 12),
            const Text('Comparable sales',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(_comparablesText(record, brief: false),
                style: const TextStyle(fontSize: 13, height: 1.5)),
            const SizedBox(height: 12),
            const Text('Assessment history',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(_assessmentText(record),
                style: const TextStyle(fontSize: 13, height: 1.5)),
            const SizedBox(height: 12),
            const Text('Why the estimate is what it is',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '${record.valuation.methodologyNote}\n\n'
              'Evidence weights: recent comparable sales (strongest) > '
              'subject sale history > property characteristics > BC '
              'Assessment (input only, never market value) > permits > '
              'confirmed renovations > visible condition > \$/sqft > lot '
              'value > market conditions.',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            if (record.valuation.adjustments.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Adjustments applied',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(record.valuation.adjustments.join('\n'),
                  style: const TextStyle(fontSize: 13, height: 1.5)),
            ],
          ],
        ),
      ),
    );
  }

  // ----- text builders (honest empty states) -------------------------------

  String? _propertyDetailsText(PropertyRecord record) {
    final c = record.characteristics;
    if (c == null) return null;
    final parts = <String>[];
    if (c.yearBuilt != null) parts.add('Year built: ${c.yearBuilt}');
    if (c.bedrooms != null) parts.add('Bedrooms: ${c.bedrooms}');
    if (c.bathrooms != null) parts.add('Bathrooms: ${c.bathrooms}');
    if (c.buildingAreaSqft != null) {
      parts.add('Building area: ${c.buildingAreaSqft!.toStringAsFixed(0)} sq ft');
    }
    if (c.lotSizeSqft != null) {
      parts.add('Lot size: ${c.lotSizeSqft!.toStringAsFixed(0)} sq ft');
    }
    if (c.basementSuite != null) {
      parts.add('Basement suite: ${c.basementSuite! ? 'yes' : 'no'}');
    }
    if (parts.isEmpty) return null;
    return '${parts.join('\n')}\nSource: ${c.evidence.label}';
  }

  String _assessmentText(PropertyRecord record) {
    final a = record.assessment;
    if (a == null) {
      return 'BC Assessment data is unavailable — BC Assessment has no '
          'public API, so assessed values cannot be retrieved automatically. '
          'Assessment value and current market value can differ; the '
          'assessment is shown separately from the market estimate and is '
          'never used as the market value.';
    }
    final parts = <String>['Source: ${a.sourceLabel}'];
    if (a.assessmentYear != null) {
      parts.add('Assessment year: ${a.assessmentYear}');
    }
    if (a.landValue != null) parts.add('Land: ${_money(a.landValue)}');
    if (a.improvementsValue != null) {
      parts.add('Improvements: ${_money(a.improvementsValue)}');
    }
    if (a.totalValue != null) {
      parts.add('Total assessed value: ${_money(a.totalValue)}');
    }
    return '${parts.join('\n')}\n\nAssessment is a data input, not the market value.';
  }

  String _permitText(PropertyRecord record) {
    final parts = <String>[];
    if (record.permitHistory.isEmpty) {
      parts.add('No permit records retrieved — municipal permit lookup is '
          'not integrated yet. Absence of a permit does not mean no '
          'renovation occurred.');
    } else {
      for (final p in record.permitHistory) {
        parts.add('PERMIT FOUND — ${p.type} (${p.municipality}'
            '${p.issuedDate != null ? ', ${p.issuedDate}' : ''})');
      }
    }
    for (final r in record.knownRenovations) {
      parts.add('${r.evidence.label} — ${r.description}'
          '${r.year != null ? ' (${r.year})' : ''}'
          '${r.sourceDetail != null ? ' — ${r.sourceDetail}' : ''}');
    }
    return parts.join('\n\n');
  }

  String _salesText(PropertyRecord record) {
    final parts = <String>[];
    if (record.recentSales.isEmpty) {
      parts.add('No recorded sale history for this property.');
    } else {
      for (final s in record.recentSales) {
        parts.add('${_money(s.salePrice)} — '
            '${s.saleDate.toIso8601String().substring(0, 10)} '
            '(${s.sourceLabel})');
      }
    }
    parts.add('');
    if (record.comparableSales.isEmpty) {
      parts.add('No comparable sales retrieved — the comparable-sales '
          'source is not connected (MLS sold data requires licensed '
          'realtor access).');
    } else {
      parts.add(_comparablesText(record, brief: true));
    }
    return parts.join('\n');
  }

  String _comparablesText(PropertyRecord record, {required bool brief}) {
    if (record.comparableSales.isEmpty) {
      return 'No comparable sales — the authorized sold-data source is '
          'not connected, so no comparables were invented. The valuation '
          'stays in its insufficient-data state until a licensed source '
          'is integrated.';
    }
    return record.comparableSales.map((c) {
      final bits = <String>[c.address];
      if (c.salePrice != null) bits.add('Sold: ${_money(c.salePrice)}');
      if (c.saleDate != null) bits.add('Date: ${c.saleDate}');
      if (c.distanceKm != null) {
        bits.add('Distance: ${c.distanceKm!.toStringAsFixed(1)} km');
      }
      bits.add('Similarity: ${c.similarityScore.toStringAsFixed(0)}/100');
      if (!brief) {
        if (c.bedrooms != null) bits.add('Beds: ${c.bedrooms}');
        if (c.bathrooms != null) bits.add('Baths: ${c.bathrooms}');
        if (c.buildingAreaSqft != null) {
          bits.add('Sqft: ${c.buildingAreaSqft!.toStringAsFixed(0)}');
          if (c.salePrice != null && c.buildingAreaSqft! > 0) {
            bits.add('\$/sqft: ${(c.salePrice! / c.buildingAreaSqft!).toStringAsFixed(0)}');
          }
        }
        if (c.adjustments.isNotEmpty) {
          bits.add('Adjustments: ${c.adjustments.join('; ')}');
        }
      }
      return bits.join(' • ');
    }).join('\n\n');
  }

  String _conditionText(PropertyRecord record) {
    if (record.conditionObservations.isEmpty) {
      return 'No visual observations available.';
    }
    return record.conditionObservations
        .map((o) =>
            '[${o.area}] ${o.observation} (${o.evidence.label})')
        .join('\n\n');
  }

  String _adjustmentsText(PropertyRecord record) {
    if (record.valuation.adjustments.isEmpty) {
      return 'No adjustments — no comparable sales to adjust.';
    }
    return record.valuation.adjustments.join('\n');
  }

  String _money(double? v) {
    if (v == null) return '—';
    return '\$${v.toStringAsFixed(0).replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        )}';
  }

  String _confidencePct(ValuationConfidence c) => switch (c) {
        ValuationConfidence.high => '80–95%',
        ValuationConfidence.medium => '55–79%',
        ValuationConfidence.low => 'below 55%',
      };

  // ----- address form ------------------------------------------------------

  Future<void> _showAddressForm() async {
    final appState = context.read<AppState>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Property address'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter the confirmed property address. The address is never '
                'guessed from the photo.',
                style: TextStyle(fontSize: 12, color: SnapColors.textMuted),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _street,
                textCapitalization: TextCapitalization.words,
                decoration:
                    const InputDecoration(labelText: 'Street address'),
              ),
              TextField(
                controller: _city,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'City'),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _province,
                      textCapitalization: TextCapitalization.characters,
                      decoration:
                          const InputDecoration(labelText: 'Province'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _postal,
                      textCapitalization: TextCapitalization.characters,
                      decoration:
                          const InputDecoration(labelText: 'Postal code'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _savingAddress
                ? null
                : () async {
                    final address = PropertyAddress(
                      street: _street.text.trim(),
                      city: _city.text.trim(),
                      province: _province.text.trim().isEmpty
                          ? 'BC'
                          : _province.text.trim(),
                      postalCode: _postal.text.trim().isEmpty
                          ? null
                          : _postal.text.trim(),
                    );
                    if (!address.isComplete) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Street and city are required.'),
                        ),
                      );
                      return;
                    }
                    setState(() => _savingAddress = true);
                    try {
                      await appState.setPropertyAddress(address);
                    } finally {
                      if (mounted) setState(() => _savingAddress = false);
                    }
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
            child: Text(_savingAddress ? 'Saving…' : 'Save address'),
          ),
        ],
      ),
    );
    // Refresh after the dialog closes (report re-generated with address).
    if (mounted) setState(() {});
  }
}
