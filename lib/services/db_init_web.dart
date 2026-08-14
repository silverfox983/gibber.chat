import 'package:sqflite_common/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

Future<void> initDatabase() async {
  databaseFactory = databaseFactoryFfiWebNoWebWorker;
}

DatabaseFactory getDatabaseFactory() => databaseFactoryFfiWebNoWebWorker;