library sembast.exception_test;

// basically same as the io runner but with extra output
import 'package:sembast/sembast.dart';

import 'test_common.dart';

void main() {
  defineTests(memoryDatabaseContext);
}

void defineTests(DatabaseTestContext ctx) {
  group('exception', () {
    Database db;

    tearDown(() {
      return db?.close();
    });

    test('put', () async {
      db = await setupForTest(ctx, 'compat/exception/put_date_time.db');
      try {
        await db.put(DateTime.now());
        fail("should fail");
      } on ArgumentError catch (_) {}
    });
  });
}
