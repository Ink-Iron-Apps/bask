import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/download_utils.dart';

void main() {
  group('canManageRuleWhileBusy', () {
    test('a rule stays reachable while its download runs', () {
      // The bug: a show downloading for hours left its rule unreachable, so
      // deleting the rule and starting over was the only way to change it.
      expect(canManageRuleWhileBusy(isQueueing: false, hasSyncRule: true), isTrue);
    });

    test('nothing to manage without a rule', () {
      expect(canManageRuleWhileBusy(isQueueing: false, hasSyncRule: false), isFalse);
    });

    test('stays shut while the queue is still being built', () {
      // Brief, and mutating the rule mid-build races the rows being inserted.
      expect(canManageRuleWhileBusy(isQueueing: true, hasSyncRule: true), isFalse);
    });

    test('queueing without a rule is also shut', () {
      expect(canManageRuleWhileBusy(isQueueing: true, hasSyncRule: false), isFalse);
    });
  });
}
