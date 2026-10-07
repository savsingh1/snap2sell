# Firebase setup guide (post-MVP)

The MVP is local-first on purpose: no accounts, no backend, works offline.
When you're ready for sync, auth, and cloud photos, follow these steps.
The app's persistence layer was designed for this swap — see step 4.

## 1. Create the Firebase project

1. Go to https://console.firebase.google.com/ (sign in with
   `zoomindustriesltd@gmail.com`).
2. Add project → name it `snap2sell` (ID will be something like
   `snap2sell-xxxxx`).
3. Disable Google Analytics for now (optional; can enable later).

## 2. Register the apps

- **Android:** Add app → package name `ca.zoomindustries.snap2sell` →
  download `google-services.json` → place in `android/app/`.
- **iOS:** Add app → bundle ID `ca.zoomindustries.snap2sell` →
  download `GoogleService-Info.plist` → place in `ios/Runner/`
  (add it to the Xcode project via Runner target).

## 3. Add FlutterFire dependencies

```bash
dart pub global activate flutterfire_cli
flutterfire configure --project=snap2sell-xxxxx   # generates lib/firebase_options.dart
```

```yaml
# pubspec.yaml additions
dependencies:
  firebase_core: ^3.6.0
  firebase_auth: ^5.3.1
  cloud_firestore: ^5.5.0
  firebase_storage: ^12.3.7
```

In `main.dart`, before `runApp`:

```dart
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(...);
}
```

## 4. Swap the storage backend (single-class change)

`AppState` depends only on the `StorageService` interface
(`lib/services/storage_service.dart`). Implement it with Firestore:

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class FirestoreStorageService implements StorageService {
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(FirebaseAuth.instance.currentUser!.uid)
          .collection('items');

  @override
  Future<List<Item>> loadItems() async {
    final snap = await _col.orderBy('createdAt', descending: true).get();
    return snap.docs.map((d) => Item.fromJson(d.data())).toList();
  }

  @override
  Future<void> saveItems(List<Item> items) async {
    final batch = FirebaseFirestore.instance.batch();
    for (final item in items) {
      batch.set(_col.doc(item.id), item.toJson());
    }
    await batch.commit();
  }

  /// Upload a local photo, returns the download URL.
  Future<String> uploadPhoto(String itemId, String localPath) async {
    final ref = FirebaseStorage.instance
        .ref('users/${FirebaseAuth.instance.currentUser!.uid}/$itemId.jpg');
    await ref.putFile(File(localPath));
    return ref.getDownloadURL();
  }
}
```

Then in `AppState`'s constructor default (or via a service locator):

```dart
AppState({StorageService? storage, ...})
    : _storage = storage ?? FirestoreStorageService(),
```

Notes:

- `Item.toJson()` / `Item.fromJson()` already round-trip cleanly, so the
  Firestore documents need no migration.
- Photo strategy: keep `photoPath` as the local path for the MVP; after
  upload, store the download URL in a new `photoUrl` field (add it to
  `Item` + JSON). Display prefers the URL, falls back to the local file.
- Auth: start with anonymous auth (`signInAnonymously`) so existing
  local-first users keep working, then offer Google/Apple sign-in to
  claim the account. Seed: copy `LocalStorageService` items into
  Firestore once on first sign-in.

## 5. Security rules (starter)

```firestore
rules_version = '2';
service cloud.firestore {
  match /databases/{db}/documents {
    match /users/{uid}/items/{itemId} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}
```

```storage
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /users/{uid}/{file} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}
```

## 6. Cost note

Spark (free) tier comfortably covers MVP-scale usage. Set budget alerts in
Google Cloud Console before launch; photo uploads are the main cost driver.
