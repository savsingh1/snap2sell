// Category list sync guard.
//
// kCategories is the review screen's fixed dropdown list: any backend
// category missing from it is silently coerced to 'Miscellaneous'
// (see results_screen.dart). This test asserts the list covers every
// category the backend can return.
//
// The backend category list below mirrors the backend prompt enum in
// functions/analyze-product/index.js and must be kept in sync with it:
// if a category is added or renamed there, update both that enum and
// kCategories, then update this list.

import 'package:flutter_test/flutter_test.dart';
import 'package:snap2sell/screens/results_screen.dart';

/// Every category the analyze-product backend can return.
const List<String> kBackendCategories = [
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
  'Automotive',
  'Miscellaneous',
];

void main() {
  group('kCategories', () {
    test('contains every category the backend can return', () {
      for (final category in kBackendCategories) {
        expect(
          kCategories,
          contains(category),
          reason: 'kCategories is missing backend category "$category"; '
              'results in that category would be coerced to Miscellaneous',
        );
      }
    });

    test('contains Automotive for vehicle listings', () {
      expect(kCategories, contains('Automotive'));
    });
  });
}
