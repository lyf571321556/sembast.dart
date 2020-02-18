library sembast.jdb_factory_memory;

import 'dart:async';

import 'package:sembast/src/api/protected/jdb.dart';
import 'package:sembast/src/api/record_ref.dart';
import 'package:sembast/src/common_import.dart';
import 'package:sembast/src/jdb.dart' as jdb;
import 'package:sembast/src/key_utils.dart';
import 'package:sembast/src/record_impl.dart';
import 'package:sembast/src/sembast_impl.dart';

/// In memory jdb.
class JdbFactoryMemory implements jdb.JdbFactory {
  final _dbs = <String, JdbDatabaseMemory>{};

  @override
  Future<jdb.JdbDatabase> open(String path) async {
    var db = _dbs[path];
    if (db == null) {
      db = JdbDatabaseMemory(this, path);
      db._closed = false;
      _dbs[path] = db;
    }
    return db;
  }

  @override
  Future delete(String path) async {
    _dbs.remove(path);
  }

  @override
  Future<bool> exists(String path) async {
    return _dbs.containsKey(path);
  }

  @override
  String toString() => 'JdbFactoryMemory(${_dbs.length} dbs)';
}

/// Simple transaction
class JdbTransactionEntryMemory extends JdbEntryMemory {
  /// Debug map.
  @override
  Map<String, dynamic> exportToMap() {
    var map = <String, dynamic>{
      if (id != null) 'id': id,
      if (deleted ?? false) 'deleted': true
    };
    return map;
  }
}

bool _isMainStore(String name) => name == null || name == dbMainStore;

/// In memory entry.
class JdbEntryMemory implements jdb.JdbReadEntry {
  @override
  int id;

  @override
  dynamic value;

  @override
  RecordRef record;

  @override
  bool deleted;

  /// Debug map.
  Map<String, dynamic> exportToMap() {
    var map = <String, dynamic>{
      'id': id,
      'value': <String, dynamic>{
        if (!_isMainStore(record?.store?.name)) 'store': record.store.name,
        'key': record?.key,
        'value': value,
        if (deleted ?? false) 'deleted': true
      }
    };
    return map;
  }

  @override
  String toString() => exportToMap().toString();
}

/// In memory database.
class JdbDatabaseMemory implements jdb.JdbDatabase {
  int _lastId = 0;

  // ignore: unused_field
  bool _closed = false;

  int get _nextId => ++_lastId;

  // ignore: unused_field
  final JdbFactoryMemory _factory;

  // ignore: unused_field
  final String _path;
  final _entries = <JdbEntryMemory>[];
  final _infoEntries = <String, jdb.JdbInfoEntry>{};
  final _revisionUpdatesCtrl = StreamController<int>.broadcast();

  /// Debug map.
  Map<String, dynamic> toDebugMap() {
    var map = <String, dynamic>{
      'entries':
          _entries.map((entry) => entry.exportToMap()).toList(growable: false),
      'infos': (List<jdb.JdbInfoEntry>.from(_infoEntries.values)
            ..sort((entry1, entry2) => entry1.id.compareTo(entry2.id)))
          .map((info) => info.exportToMap())
          .toList(growable: false),
    };
    return map;
  }

  int _revision;

  @override
  Stream<jdb.JdbReadEntry> get entries async* {
    for (var entry in _entries) {
      _revision = entry.id;
      yield entry;
    }
  }

  /// New in memory database.
  JdbDatabaseMemory(this._factory, this._path);

  @override
  void close() {
    _closed = false;
  }

  @override
  Future<jdb.JdbInfoEntry> getInfoEntry(String id) async {
    return _infoEntries[id];
  }

  @override
  Future setInfoEntry(jdb.JdbInfoEntry entry) async {
    _setInfoEntry(entry);
  }

  void _setInfoEntry(jdb.JdbInfoEntry entry) {
    _infoEntries[entry.id] = entry;
  }

  JdbEntryMemory _writeEntryToMemory(jdb.JdbWriteEntry jdbWriteEntry) {
    var record = jdbWriteEntry.record;
    var entry = JdbEntryMemory()
      ..record = record
      ..value = jdbWriteEntry.value
      ..id = _nextId
      ..deleted = jdbWriteEntry.deleted;
    return entry;
  }

  @override
  Future<int> addEntries(List<jdb.JdbWriteEntry> entries) async {
    return _addEntries(entries);
  }

  int _addEntries(List<jdb.JdbWriteEntry> entries) {
    // Should import?
    var revision = _lastEntryId;
    var upToDate = (_revision ?? 0) == revision;
    if (!upToDate) {
      _revisionUpdatesCtrl.add(revision);
    }
    // devPrint('adding ${entries.length} uptodate $upToDate');
    for (var jdbWriteEntry in entries) {
      // remove existing
      var record = jdbWriteEntry.record;
      _entries.removeWhere((entry) => entry.record == record);
      var entry = _writeEntryToMemory(jdbWriteEntry);
      _entries.add(entry);
      (jdbWriteEntry.txnRecord?.record as ImmutableSembastRecordJdb)?.revision =
          entry.id;
    }
    if (upToDate) {
      _revision = _lastEntryId;
    }

    return _lastEntryId;
  }

  String _storeLastIdKey(String store) {
    return '${store}_store_last_id';
  }

  @override
  Future<List<int>> generateUniqueIntKeys(String store, int count) async {
    var keys = <int>[];
    var infoKey = _storeLastIdKey(store);
    var lastId = ((await getInfoEntry(infoKey))?.value as int) ?? 0;
    for (var i = 0; i < count; i++) {
      keys.add(++lastId);
    }
    await setInfoEntry(jdb.JdbInfoEntry()
      ..id = infoKey
      ..value = lastId);

    return keys;
  }

  @override
  Future<List<String>> generateUniqueStringKeys(
          String store, int count) async =>
      List.generate(count, (_) => generateStringKey());

  @override
  Stream<jdb.JdbEntry> entriesAfterRevision(int revision) async* {
    revision ??= 0;
    // Copy the list
    for (var entry in _entries.toList(growable: false)) {
      if ((entry.id ?? 0) > revision) {
        yield entry;
      }
    }
  }

  @override
  Future<int> getRevision() async {
    try {
      return _lastEntryId;
    } catch (e) {
      return null;
    }
  }

  int get _lastEntryId => _entries.isEmpty ? 0 : _entries.last.id;

  @override
  Stream<int> get revisionUpdate => _revisionUpdatesCtrl.stream;

  @override
  Future<StorageJdbWriteResult> writeIfRevision(
      StorageJdbWriteQuery query) async {
    var expectedRevision = query.revision ?? 0;
    var readRevision = _lastEntryId;
    var success = (expectedRevision == readRevision);

    if (success) {
      // _entries.add(JdbTransactionEntryMemory()..id = _nextId);
      if (query.entries?.isNotEmpty ?? false) {
        _addEntries(query.entries);
      }
      readRevision = _revision = _lastEntryId;
      if (query.infoEntries?.isNotEmpty ?? false) {
        for (var infoEntry in query.infoEntries) {
          _setInfoEntry(infoEntry);
        }
      }
    }
    // Also set the revision
    //if (r)
    if (_lastEntryId > 0) {
      await setInfoEntry(jdb.JdbInfoEntry()
        ..id = _revisionKey
        ..value = _lastEntryId);
    }
    return StorageJdbWriteResult(
        revision: readRevision, query: query, success: success);
  }

  @override
  Future<Map<String, dynamic>> exportToMap() async {
    return toDebugMap();
  }
}

/// last entry id inserted
const _revisionKey = 'revision';

JdbFactoryMemory _jdbFactoryMemory = JdbFactoryMemory();

/// Jdb Factory in memory
JdbFactoryMemory get jdbFactoryMemory => _jdbFactoryMemory;
