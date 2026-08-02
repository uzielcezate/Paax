// test/unit/uuid_test.dart — Phase 3.4.1 client UUID allocation.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/utils/uuid.dart';

void main() {
  test('newUuidV4 produces valid, unique v4 UUIDs', () {
    final a = newUuidV4();
    final b = newUuidV4();
    expect(isUuid(a), isTrue);
    expect(isUuid(b), isTrue);
    expect(a, isNot(b));
    // version nibble is 4, variant nibble in [8,b]
    expect(a[14], '4');
    expect('89ab'.contains(a[19].toLowerCase()), isTrue);
  });

  test('isUuid rejects legacy millis-string ids and junk', () {
    expect(isUuid('1722520000000'), isFalse); // old local id
    expect(isUuid(''), isFalse);
    expect(isUuid('not-a-uuid'), isFalse);
    expect(isUuid('603305d4-641b-4c26-a671-a94189e3d5ac'), isTrue);
  });
}
