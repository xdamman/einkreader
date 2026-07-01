import 'package:einkreader/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isVersionNewer', () {
    test('detects a newer release', () {
      expect(isVersionNewer('0.1.4', '0.1.3'), isTrue);
      expect(isVersionNewer('0.2.0', '0.1.9'), isTrue);
      expect(isVersionNewer('1.0.0', '0.9.9'), isTrue);
      expect(isVersionNewer('0.1.10', '0.1.9'), isTrue);
    });

    test('same or older is not newer', () {
      expect(isVersionNewer('0.1.3', '0.1.3'), isFalse);
      expect(isVersionNewer('0.1.2', '0.1.3'), isFalse);
      expect(isVersionNewer('0.1.3', '0.2.0'), isFalse);
    });

    test('ignores +build suffix and a leftover v', () {
      expect(isVersionNewer('0.1.3', '0.1.3+3'), isFalse);
      expect(isVersionNewer('0.1.4+1', '0.1.3+9'), isTrue);
      expect(isVersionNewer('v0.1.4'.replaceFirst('v', ''), '0.1.3'), isTrue);
    });

    test('handles differing component counts', () {
      expect(isVersionNewer('0.2', '0.1.9'), isTrue);
      expect(isVersionNewer('0.1', '0.1.0'), isFalse);
    });
  });
}
