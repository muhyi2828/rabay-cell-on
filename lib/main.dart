import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:supabase_flutter/supabase_flutter.dart';


final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

const MethodChannel _nativeAlarmChannel = MethodChannel('rabay_cell/alarm');
const MethodChannel _photoPickerChannel = MethodChannel('rabay_cell/photo_picker');

Future<void> initNotifications() async {
  tzdata.initializeTimeZones();
  tz.setLocalLocation(tz.getLocation('Asia/Jakarta'));

  const androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  const darwinSettings = DarwinInitializationSettings();

  const settings = InitializationSettings(
    android: androidSettings,
    iOS: darwinSettings,
  );

  await notifications.initialize(settings);

  // Android 13+ requires notification permission before reminders can appear.
  final android = notifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  await android?.requestNotificationsPermission();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

await Supabase.initialize(
    url: 'https://kgdpzpvqdmohydzmmtdz.supabase.co',
    publishableKey: 'sb_publishable_D6Je5aCl5PYezbrnTkWTyA_OzAdcGyR',
  );

  await initializeDateFormatting('id_ID', null);
  await initNotifications();
  await PosDb.instance.init();
  await restoreClosingReminder();

  runApp(const PosApp());
}

Future<void> restoreClosingReminder() async {
  try {
    final enabled = (await PosDb.instance.setting('closing_reminder_enabled') ?? 'true') == 'true';
    if (!enabled) {
      await _nativeAlarmChannel.invokeMethod<void>('cancelDailyAlarm');
      return;
    }
    final time = await PosDb.instance.setting('closing_time');
    final message = await PosDb.instance.setting('closing_message');
    final sound = (await PosDb.instance.setting('closing_sound') ?? 'true') == 'true';
    if (time == null || message == null || message.trim().isEmpty) return;
    final parts = time.trim().split(':');
    if (parts.length != 2) return;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) return;
    await scheduleClosingReminder(
      hour: hour,
      minute: minute,
      message: message,
      soundEnabled: sound,
    );
  } catch (_) {
    // App startup should continue even if notification scheduling is unavailable.
  }
}


Future<void> scheduleClosingReminder({
  required int hour,
  required int minute,
  required String message,
  required bool soundEnabled,
}) async {
  // Native Android alarm keeps sounding until the user presses BERHENTI.
  // Resaving replaces the existing native PendingIntent for the daily alarm.
  await _nativeAlarmChannel.invokeMethod<void>('scheduleDailyAlarm', <String, Object>{
    'hour': hour,
    'minute': minute,
    'message': message,
    'soundEnabled': soundEnabled,
  });
}
 
final money = NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);
final dateFmt = DateFormat('dd MMM yyyy, HH:mm', 'id_ID');

// Foto produk disimpan sebagai BLOB di SQLite privat aplikasi; tidak membuat file gambar publik.
Widget _productThumbnail(Uint8List? imageData, {double size = 38}) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: const Color(0xFFDCE9E7),
      borderRadius: BorderRadius.circular(8),
    ),
    clipBehavior: Clip.antiAlias,
    child: imageData != null && imageData.isNotEmpty
        ? Image.memory(imageData, fit: BoxFit.cover, errorBuilder: (_, __, ___) =>
            const Icon(Icons.image_outlined, size: 19, color: Colors.black38))
        : const Icon(Icons.image_outlined, size: 19, color: Colors.black38),
  );
}

// Data lama mungkin memiliki tanggal kosong atau format yang tidak valid.
// Fungsi ini mencegah satu baris rusak membuat seluruh daftar menjadi kotak abu-abu.
DateTime _parseJakartaDate(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.toLowerCase() == 'null') {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  final numeric = int.tryParse(text);
  if (numeric != null) {
    final millis = numeric.abs() < 100000000000 ? numeric * 1000 : numeric;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).add(const Duration(hours: 7));
  }
  final parsed = DateTime.parse(text);
  // ISO values with Z/offset represent an absolute instant; display it in GMT+07:00.
  if (RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(text)) {
    return parsed.toUtc().add(const Duration(hours: 7));
  }
  // Older SQLite timestamps have no timezone suffix and were recorded in local Jakarta time.
  return parsed;
}

DateTime safeDateTime(Object? value) {
  try {
    return _parseJakartaDate(value);
  } catch (_) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}

String safeDateFormat(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.toLowerCase() == 'null') return '-';
  try {
    return dateFmt.format(_parseJakartaDate(value));
  } catch (_) {
    return '-';
  }
}

String sessionDateFormat(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.toLowerCase() == 'null') return '-';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
  try {
    final date = _parseJakartaDate(value);
    return '${date.day.toString().padLeft(2, '0')} ${months[date.month - 1]} ${date.year}';
  } catch (_) {
    return '-';
  }
}

class PosApp extends StatelessWidget {
  const PosApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Rabay Cell',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF009688)),
      scaffoldBackgroundColor: const Color(0xFFF3FAF9),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF008F83),
        foregroundColor: Colors.white,
        centerTitle: false,
        elevation: 0,
        surfaceTintColor: Color(0xFF008F83),
      ),
      cardTheme: CardThemeData(elevation: 0, color: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.grey.shade300)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: Colors.grey.shade300)),
      ),
    ),
    home: const AuthGate(),
  );
}

class PosDb {
  PosDb._();
  static final instance = PosDb._();
  Database? _db;
  Database get db => _db!;
  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _db = await openDatabase(p.join(dir.path, 'pos_offline.db'), version: 6,
      onCreate: (d, v) async {
        await d.execute('''CREATE TABLE products(
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, code TEXT NOT NULL UNIQUE,
          barcode TEXT NOT NULL UNIQUE, cost INTEGER NOT NULL, price INTEGER NOT NULL, stock INTEGER NOT NULL DEFAULT 0,
          category TEXT NOT NULL DEFAULT '', image_data BLOB, updated_at TEXT NOT NULL)''');
        await d.execute('''CREATE TABLE transactions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, total INTEGER NOT NULL, profit INTEGER NOT NULL,
          paid INTEGER NOT NULL, change_amount INTEGER NOT NULL, created_at TEXT NOT NULL,
          updated_at TEXT, edit_count INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'completed', session_id INTEGER)''');
                await d.execute('''CREATE TABLE transaction_items(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          transaction_id INTEGER NOT NULL,
          product_id INTEGER,
          product_name TEXT NOT NULL,
          barcode TEXT NOT NULL,
          qty INTEGER NOT NULL,
          cost_snapshot INTEGER NOT NULL,
          price_snapshot INTEGER NOT NULL,
          cancelled INTEGER NOT NULL DEFAULT 0,
          FOREIGN KEY(transaction_id) REFERENCES transactions(id)
        )''');
        await d.execute('''CREATE TABLE audit_log(
          id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_id INTEGER NOT NULL,
          changed_at TEXT NOT NULL, old_total INTEGER NOT NULL, new_total INTEGER NOT NULL,
          note TEXT NOT NULL)''');
        await d.execute('''CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)''');
        await d.execute('''CREATE TABLE sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, closed_at TEXT, title TEXT NOT NULL DEFAULT '', total_sales INTEGER NOT NULL DEFAULT 0, total_profit INTEGER NOT NULL DEFAULT 0, transaction_count INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0)''');
        await d.insert('sessions', {'started_at': DateTime.now().toIso8601String()});
      },
      onUpgrade: (d, oldVersion, newVersion) async {
        if (oldVersion < 2) {
            
          await d.execute("ALTER TABLE transactions ADD COLUMN status TEXT NOT NULL DEFAULT 'completed'");
          await d.execute('ALTER TABLE transactions ADD COLUMN session_id INTEGER');
          await d.execute('''CREATE TABLE sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, closed_at TEXT, total_sales INTEGER NOT NULL DEFAULT 0, total_profit INTEGER NOT NULL DEFAULT 0, transaction_count INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0)''');
          await d.insert('sessions', {'started_at': DateTime.now().toIso8601String()});
          final active = await d.query('sessions', orderBy: 'id DESC', limit: 1);
          await d.update('transactions', {'session_id': active.first['id']}, where: 'session_id IS NULL');
        }
          if (oldVersion < 3) {
  await d.execute(
    'ALTER TABLE transaction_items '
    'ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0',
  );
          }
          if (oldVersion < 4) {
            await d.execute("ALTER TABLE products ADD COLUMN category TEXT NOT NULL DEFAULT ''");
          }
          if (oldVersion < 5) {
            await d.execute('ALTER TABLE products ADD COLUMN image_data BLOB');
          }
          if (oldVersion < 6) {
            await d.execute("ALTER TABLE sessions ADD COLUMN title TEXT NOT NULL DEFAULT ''");
          }
      });
      // Non-destructive repair for older rows whose timestamp field is blank.
      // Exact historical time cannot be reconstructed; use the repair time only for blank rows.
      final repairTime = DateTime.now().toIso8601String();
      await db.rawUpdate("UPDATE transactions SET created_at = ? WHERE created_at IS NULL OR TRIM(created_at) = ''", [repairTime]);
      await db.rawUpdate("UPDATE sessions SET started_at = ? WHERE started_at IS NULL OR TRIM(started_at) = ''", [repairTime]);

      final activeSessions = await db.query('sessions', where: 'archived = 0', orderBy: 'id DESC', limit: 1);
      if (activeSessions.isEmpty) await db.insert('sessions', {'started_at': DateTime.now().toIso8601String()});
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<List<Map<String, Object?>>> products({String query = ''}) async {
    final rows = query.trim().isEmpty
        ? await db.query('products', orderBy: 'name COLLATE NOCASE')
        : await db.query(
            'products',
            where: 'name LIKE ? OR code LIKE ? OR barcode LIKE ? OR category LIKE ?',
            whereArgs: ['%$query%', '%$query%', '%$query%', '%$query%'],
            orderBy: 'name COLLATE NOCASE',
          );

    // Read product timestamps without changing them. updated_at means the last
    // time the owner saved the product form, not the last stock movement.
    return rows;
  }
  Future<List<String>> categories() async {
    final rows = await db.rawQuery("SELECT DISTINCT TRIM(category) AS category FROM products WHERE TRIM(category) <> '' ORDER BY category COLLATE NOCASE");
    return rows.map((r) => (r['category'] as String?) ?? '').where((v) => v.isNotEmpty).toList();
  }

  Future<Map<String, Object?>?> productByBarcode(String barcode) async {
    final code = barcode.trim();
    final r = await db.query(
      'products',
      where: 'barcode = ? COLLATE NOCASE OR code = ? COLLATE NOCASE',
      whereArgs: [code, code],
      limit: 1,
    );
    return r.isEmpty ? null : r.first;
  }

  Future<Map<String, Object?>?> productById(int id) async {
    final r = await db.query('products', where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isEmpty ? null : r.first;
  }
  Future<void> saveProduct({int? id, required String name, required String code, required String barcode,
    required int cost, required int price, required int stock, required String category, Uint8List? imageData}) async {
    final data = {'name': name.trim(), 'code': code.trim(), 'barcode': barcode.trim(),
      'cost': cost, 'price': price, 'stock': stock, 'category': category.trim(),
      'image_data': imageData, 'updated_at': DateTime.now().toIso8601String()};
    if (id == null) {
      await db.insert('products', data);
    } else {
      await db.update('products', data, where: 'id = ?', whereArgs: [id]);
    }
  }

  Future<void> deleteProduct(int id) async {
    // Prevent deleting a product that is still referenced by the saved cart.
    final savedCart = await loadCart();
    final cartItems = (savedCart?['items'] as List? ?? []).whereType<Map>();
    if (cartItems.any((row) => row['productId'] == id)) {
      throw Exception('Barang masih ada di keranjang. Hapus dari keranjang terlebih dahulu.');
    }
    await db.delete('products', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> checkout(List<CartLine> cart, int paid) async {
    if (cart.isEmpty) throw Exception('Keranjang masih kosong.');
    final total = cart.fold<int>(0, (s, x) => s + x.price * x.qty);
    if (paid < total) throw Exception('Uang pembayaran kurang.');
    final now = DateTime.now().toIso8601String();
    final activeSession = await db.query('sessions', where: 'archived = 0', orderBy: 'id DESC', limit: 1);
    final sessionId = activeSession.first['id'] as int;
    await db.transaction((txn) async {
      var profit = 0;
      for (final line in cart) {
        final rows = await txn.query('products', where: 'id = ?', whereArgs: [line.productId], limit: 1);
        if (rows.isEmpty) throw Exception('Barang ${line.name} tidak ditemukan.');
        // Stok boleh menjadi minus; transaksi tetap diproses sesuai permintaan pemilik.
        profit += (line.price - line.cost) * line.qty;
      }
      final id = await txn.insert('transactions', {'total': total, 'profit': profit, 'paid': paid,
        'change_amount': paid-total, 'created_at': now, 'updated_at': null, 'edit_count': 0, 'status': 'completed', 'session_id': sessionId});
      for (final line in cart) {
        await txn.insert('transaction_items', {'transaction_id': id, 'product_id': line.productId,
          'product_name': line.name, 'barcode': line.barcode, 'qty': line.qty,
          'cost_snapshot': line.cost, 'price_snapshot': line.price});
        await txn.rawUpdate('UPDATE products SET stock = stock - ? WHERE id = ?',
          [line.qty, line.productId]);
      }
    });
    await backup();
  }

  Future<List<Map<String, Object?>>> transactions({String query = ''}) async {
    final active = await db.query('sessions', where: 'archived = 0', orderBy: 'id DESC', limit: 1);
    if (active.isEmpty) return [];
    return db.query('transactions', where: 'session_id = ?', whereArgs: [active.first['id']], orderBy: 'id DESC', limit: 500);
  }
  Future<List<Map<String, Object?>>> items(int transactionId) => db.query('transaction_items',
    where: 'transaction_id = ?', whereArgs: [transactionId], orderBy: 'id');

  Future<void> cancelTransaction(int transactionId) async {
    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final transactionRows = await txn.query(
        'transactions',
        where: 'id = ?',
        whereArgs: [transactionId],
        limit: 1,
      );

      if (transactionRows.isEmpty) {
        throw Exception('Transaksi tidak ditemukan.');
      }

      final transaction = transactionRows.first;
      if ((transaction['status'] as String? ?? 'completed') == 'cancelled') {
        throw Exception('Transaksi sudah dibatalkan.');
      }

      final oldTotal = transaction['total'] as int;
      final activeItems = await txn.query(
        'transaction_items',
        where: 'transaction_id = ? AND cancelled = 0',
        whereArgs: [transactionId],
      );

      for (final item in activeItems) {
        final productId = item['product_id'];
        if (productId != null) {
          await txn.rawUpdate(
            'UPDATE products SET stock = stock + ? WHERE id = ?',
            [item['qty'], productId],
          );
        }

        await txn.update(
          'transaction_items',
          {'cancelled': 1},
          where: 'id = ?',
          whereArgs: [item['id']],
        );
      }

      await txn.update(
        'transactions',
        {
          'total': 0,
          'profit': 0,
          'change_amount': transaction['paid'] as int,
          'status': 'cancelled',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [transactionId],
      );

      await txn.insert('audit_log', {
        'transaction_id': transactionId,
        'changed_at': now,
        'old_total': oldTotal,
        'new_total': 0,
        'note': 'Transaksi dibatalkan; stok barang dikembalikan',
      });
    });

    await backup();
  }

  Future<void> cancelTransactionItem(int itemId) async {
  final now = DateTime.now().toIso8601String();

  await db.transaction((txn) async {
    final itemRows = await txn.query(
      'transaction_items',
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );

    if (itemRows.isEmpty) {
      throw Exception('Barang transaksi tidak ditemukan.');
    }

    final item = itemRows.first;

    if ((item['cancelled'] as int? ?? 0) == 1) {
      throw Exception('Barang ini sudah dibatalkan.');
    }

    final transactionId = item['transaction_id'] as int;

    final transactionRows = await txn.query(
      'transactions',
      where: 'id = ?',
      whereArgs: [transactionId],
      limit: 1,
    );

    if (transactionRows.isEmpty) {
      throw Exception('Transaksi tidak ditemukan.');
    }

    final transaction = transactionRows.first;

    if ((transaction['status'] as String? ?? 'completed') == 'cancelled') {
      throw Exception('Transaksi sudah dibatalkan.');
    }

    final oldTotal = transaction['total'] as int;
    final paid = transaction['paid'] as int;
    final productId = item['product_id'];

    // Kembalikan stok barang yang dibatalkan.
    if (productId != null) {
      await txn.rawUpdate(
        'UPDATE products SET stock = stock + ? WHERE id = ?',
        [item['qty'], productId],
      );
    }

    // Tandai barang sebagai dibatalkan, jangan hapus riwayatnya.
    await txn.update(
      'transaction_items',
      {'cancelled': 1},
      where: 'id = ?',
      whereArgs: [itemId],
    );

    // Hitung ulang total dan keuntungan dari barang yang masih aktif.
    final activeItems = await txn.query(
      'transaction_items',
      where: 'transaction_id = ? AND cancelled = 0',
      whereArgs: [transactionId],
    );

    var newTotal = 0;
    var newProfit = 0;

    for (final row in activeItems) {
      final qty = row['qty'] as int;
      final price = row['price_snapshot'] as int;
      final cost = row['cost_snapshot'] as int;

      newTotal += price * qty;
      newProfit += (price - cost) * qty;
    }

    final newStatus = activeItems.isEmpty ? 'cancelled' : 'completed';

    await txn.update(
      'transactions',
      {
        'total': newTotal,
        'profit': newProfit,
        'change_amount': paid - newTotal,
        'status': newStatus,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [transactionId],
    );

    await txn.insert('audit_log', {
      'transaction_id': transactionId,
      'changed_at': now,
      'old_total': oldTotal,
      'new_total': newTotal,
      'note': 'Barang ${item['product_name']} dibatalkan; stok dikembalikan',
    });
  });

  await backup();
}
  Future<void> editTransaction(
    int id,
    List<CartLine> replacement,
    int paid,
  ) async {
    if (replacement.isEmpty) {
      throw Exception('Transaksi tidak boleh kosong.');
    }

    final oldRows = await db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (oldRows.isEmpty) {
      throw Exception('Transaksi tidak ditemukan.');
    }

    final oldTransaction = oldRows.first;
    if ((oldTransaction['status'] as String? ?? 'completed') == 'cancelled') {
      throw Exception('Transaksi yang dibatalkan tidak bisa diubah.');
    }

    final cancelledItems = await db.query(
      'transaction_items',
      where: 'transaction_id = ? AND cancelled = 1',
      whereArgs: [id],
      limit: 1,
    );
    if (cancelledItems.isNotEmpty) {
      throw Exception(
        'Transaksi yang memiliki barang dibatalkan tidak bisa diedit.',
      );
    }

    final oldTotal = oldTransaction['total'] as int;
    final total = replacement.fold<int>(
      0,
      (sum, item) => sum + item.price * item.qty,
    );
    if (paid < total) {
      throw Exception('Uang pembayaran kurang.');
    }

    final now = DateTime.now().toIso8601String();

    await db.transaction((txn) async {
      final oldItems = await txn.query(
        'transaction_items',
        where: 'transaction_id = ?',
        whereArgs: [id],
      );

      // Kembalikan stok dari transaksi lama terlebih dahulu.
      for (final item in oldItems) {
        final productId = item['product_id'];
        if (productId != null) {
          await txn.rawUpdate(
            'UPDATE products SET stock = stock + ? WHERE id = ?',
            [item['qty'], productId],
          );
        }
      }

      var profit = 0;
      // Pastikan semua barang masih ada dan stok mencukupi setelah stok lama dikembalikan.
      for (final line in replacement) {
        final rows = await txn.query(
          'products',
          where: 'id = ?',
          whereArgs: [line.productId],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw Exception('Barang ${line.name} tidak ditemukan.');
        }
        // Stok boleh menjadi minus setelah transaksi diedit.
        profit += (line.price - line.cost) * line.qty;
      }

      // Kurangi stok sesuai transaksi baru.
      for (final line in replacement) {
        await txn.rawUpdate(
          'UPDATE products SET stock = stock - ? WHERE id = ?',
          [line.qty, line.productId],
        );
      }

      await txn.delete(
        'transaction_items',
        where: 'transaction_id = ?',
        whereArgs: [id],
      );

      for (final line in replacement) {
        await txn.insert('transaction_items', {
          'transaction_id': id,
          'product_id': line.productId,
          'product_name': line.name,
          'barcode': line.barcode,
          'qty': line.qty,
          'cost_snapshot': line.cost,
          'price_snapshot': line.price,
          'cancelled': 0,
        });
      }

      await txn.update(
        'transactions',
        {
          'total': total,
          'profit': profit,
          'paid': paid,
          'change_amount': paid - total,
          'updated_at': now,
          'edit_count': ((oldTransaction['edit_count'] as int?) ?? 0) + 1,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      await txn.insert('audit_log', {
        'transaction_id': id,
        'changed_at': now,
        'old_total': oldTotal,
        'new_total': total,
        'note': 'Transaksi diubah',
      });
    });

    await backup();
  }

  Future<Map<String, Object?>> closeSession({required String title}) async {
    final now = DateTime.now().toIso8601String();
    late Map<String, Object?> summary;
    await db.transaction((txn) async {
      final active = await txn.query('sessions', where: 'archived = 0', orderBy: 'id DESC', limit: 1);
      if (active.isEmpty) throw Exception('Sesi aktif tidak ditemukan.');
      final sid = active.first['id'] as int;
      final sums = await txn.rawQuery("SELECT COALESCE(SUM(total),0) AS sales, COALESCE(SUM(profit),0) AS profit, COUNT(*) AS cnt FROM transactions WHERE session_id = ? AND status != 'cancelled'", [sid]);
      summary = {'id': sid, 'title': title, 'started_at': active.first['started_at'], 'total_sales': sums.first['sales'], 'total_profit': sums.first['profit'], 'transaction_count': sums.first['cnt'], 'closed_at': now};
      await txn.update('sessions', {'title': title, 'closed_at': now, 'total_sales': summary['total_sales'], 'total_profit': summary['total_profit'], 'transaction_count': summary['transaction_count'], 'archived': 1}, where: 'id = ?', whereArgs: [sid]);
      await txn.insert('sessions', {'started_at': now, 'archived': 0});
    });
    await backup();
    return summary;
  }

  Future<List<Map<String, Object?>>> sessions() => db.query('sessions', where: 'archived = 1', orderBy: 'id DESC');
  Future<List<Map<String, Object?>>> sessionTransactions(int sessionId) => db.query('transactions', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'id DESC');


  // Permanently delete one archived session row and its history. Current stock is not changed.
  Future<void> deleteArchivedSession(int sessionId) async {
    await db.transaction((txn) async {
      final sessions = await txn.query(
        'sessions',
        where: 'id = ? AND archived = 1',
        whereArgs: [sessionId],
        limit: 1,
      );
      if (sessions.isEmpty) {
        throw Exception('Arsip sesi tidak ditemukan atau bukan sesi yang sudah ditutup.');
      }
      final txRows = await txn.query(
        'transactions',
        columns: ['id'],
        where: 'session_id = ?',
        whereArgs: [sessionId],
      );
      for (final row in txRows) {
        final transactionId = row['id'] as int;
        await txn.delete('audit_log', where: 'transaction_id = ?', whereArgs: [transactionId]);
        await txn.delete('transaction_items', where: 'transaction_id = ?', whereArgs: [transactionId]);
      }
      await txn.delete('transactions', where: 'session_id = ?', whereArgs: [sessionId]);
      await txn.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
    });
    await backup();
  }

  // Permanently remove one transaction from an archived session only.
  // This cleans history and recalculates the archive summary; stock is unchanged.
  Future<void> deleteArchivedTransaction(int transactionId) async {
    await db.transaction((txn) async {
      final rows = await txn.query(
        'transactions',
        where: 'id = ?',
        whereArgs: [transactionId],
        limit: 1,
      );
      if (rows.isEmpty) throw Exception('Transaksi tidak ditemukan.');
      final transaction = rows.first;
      final sessionId = transaction['session_id'] as int?;
      if (sessionId == null) throw Exception('Transaksi tidak memiliki sesi.');

      final sessionRows = await txn.query(
        'sessions',
        where: 'id = ? AND archived = 1',
        whereArgs: [sessionId],
        limit: 1,
      );
      if (sessionRows.isEmpty) {
        throw Exception('Hanya transaksi dalam arsip yang dapat dihapus di sini.');
      }

      await txn.delete('audit_log', where: 'transaction_id = ?', whereArgs: [transactionId]);
      await txn.delete('transaction_items', where: 'transaction_id = ?', whereArgs: [transactionId]);
      await txn.delete('transactions', where: 'id = ?', whereArgs: [transactionId]);

      final sums = await txn.rawQuery(
        "SELECT COALESCE(SUM(total),0) AS sales, COALESCE(SUM(profit),0) AS profit, COUNT(*) AS cnt FROM transactions WHERE session_id = ? AND status != 'cancelled'",
        [sessionId],
      );
      await txn.update(
        'sessions',
        {
          'total_sales': sums.first['sales'],
          'total_profit': sums.first['profit'],
          'transaction_count': sums.first['cnt'],
        },
        where: 'id = ?',
        whereArgs: [sessionId],
      );
    });
    await backup();
  }

  Future<void> saveCart(List<CartLine> cart, String paidText) async {
    await setSetting('cart_json', jsonEncode({'paid': paidText, 'items': cart.map((x) => {'productId': x.productId, 'name': x.name, 'barcode': x.barcode, 'cost': x.cost, 'price': x.price, 'qty': x.qty}).toList()}));
  }
  Future<Map<String, Object?>?> loadCart() async {
    final raw = await setting('cart_json');
    if (raw == null || raw.isEmpty) return null;
    try { return jsonDecode(raw) as Map<String, Object?>; } catch (_) { return null; }
  }

  Future<List<Map<String, Object?>>> audit(int id) => db.query('audit_log',
    where: 'transaction_id = ?', whereArgs: [id], orderBy: 'id DESC');

  Future<String?> setting(String key) async {
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }
  Future<void> setSetting(String key, String value) => db.insert('settings', {'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> setPin(String pin) async {
    final salt = List.generate(16, (_) => Random.secure().nextInt(256)).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    final hash = sha256.convert(utf8.encode('$salt:$pin')).toString();
    await setSetting('pin_salt', salt);
    await setSetting('pin_hash', hash);
  }
  Future<bool> verifyPin(String pin) async {
    final salt = await setting('pin_salt');
    final hash = await setting('pin_hash');
    if (salt == null || hash == null) return false;
    return sha256.convert(utf8.encode('$salt:$pin')).toString() == hash;
  }

  Future<void> _removePinSettingsFromBackup(String databasePath) async {
    Database? backupDb;
    try {
      backupDb = await openDatabase(databasePath);
      await backupDb.delete('settings', where: 'key IN (?, ?, ?)',
        whereArgs: ['pin_hash', 'pin_salt', 'owner_pin_enabled']);
    } finally {
      await backupDb?.close();
    }
  }

  Future<File> createPortableBackup() async {
    // Checkpoint SQLite WAL so the exported database includes committed changes.
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
    final dir = await getApplicationDocumentsDirectory();
    final source = File(p.join(dir.path, 'pos_offline.db'));
    if (!await source.exists()) throw Exception('Database belum tersedia.');
    final temp = await getTemporaryDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final target = File(p.join(temp.path, 'rabay_cell_backup_$stamp.db'));
    await source.copy(target.path);
    await _removePinSettingsFromBackup(target.path);
    return target;
  }

  Future<void> restorePortableBackup(String selectedPath) async {
    final selected = File(selectedPath);
    if (!await selected.exists()) throw Exception('File backup tidak ditemukan.');
    final localPinHash = await setting('pin_hash');
    final localPinSalt = await setting('pin_salt');
    final localPinEnabled = await setting('owner_pin_enabled') ?? 'true';
    final dir = await getApplicationDocumentsDirectory();
    final targetPath = p.join(dir.path, 'pos_offline.db');
    final tempPath = p.join(dir.path, 'restore_validation.db');
    final validationFile = File(tempPath);
    if (await validationFile.exists()) await validationFile.delete();
    await selected.copy(tempPath);
    Database? checkDb;
    try {
      checkDb = await openDatabase(tempPath, readOnly: true);
      final tables = await checkDb.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
      final names = tables.map((r) => r['name'] as String).toSet();
      const required = {'products', 'transactions', 'transaction_items', 'settings', 'sessions', 'audit_log'};
      if (!names.containsAll(required)) {
        throw Exception('File bukan backup Rabay Cell yang valid atau strukturnya tidak lengkap.');
      }
      final integrity = await checkDb.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw Exception('File backup rusak dan tidak bisa dipulihkan.');
      }
    } finally {
      await checkDb?.close();
    }
    // Keep a safety copy before replacing the live database.
    await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
    final safety = File(p.join(dir.path, 'pos_before_restore_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.db'));
    await File(targetPath).copy(safety.path);
    await _db?.close();
    _db = null;
    try {
      await validationFile.copy(targetPath);
      await validationFile.delete();
      await init();
      // Remove any legacy PIN bundled in the imported database, then retain only this device's PIN settings.
      await db.delete('settings', where: 'key IN (?, ?, ?)',
        whereArgs: ['pin_hash', 'pin_salt', 'owner_pin_enabled']);
      await setSetting('owner_pin_enabled', localPinEnabled);
      if (localPinHash != null) await setSetting('pin_hash', localPinHash);
      if (localPinSalt != null) await setSetting('pin_salt', localPinSalt);
    } catch (_) {
      // Restore the previous database if opening the imported database fails.
      if (await safety.exists()) await safety.copy(targetPath);
      await init();
      rethrow;
    }
  }

  Future<void> backup() async {
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
      final dir = await getApplicationDocumentsDirectory();
      final source = File(p.join(dir.path, 'pos_offline.db'));
      if (!await source.exists()) return;
      final folder = Directory(p.join(dir.path, 'backups'));
      if (!await folder.exists()) await folder.create(recursive: true);
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final backupPath = p.join(folder.path, 'pos_backup_$stamp.db');
      await source.copy(backupPath);
      await _removePinSettingsFromBackup(backupPath);
      // Keep the most recent 20 backup files.
      final files = folder.listSync().whereType<File>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final old in files.skip(20)) { await old.delete(); }
    } catch (_) {
      // Main database remains available even if a backup attempt fails.
    }
  }
}

class CartLine {
  final int productId;
  final String name, barcode;
  final Uint8List? imageData;
  final int cost, price;
  int qty;
  CartLine({required this.productId, required this.name, required this.barcode,
    this.imageData, required this.cost, required this.price, this.qty = 1});
  int get subtotal => price * qty;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int tab = 0;
  bool unlocked = false;
  bool pinEnabled = true;
  final GlobalKey<_CashierPageState> _cashierKey = GlobalKey<_CashierPageState>();
@override
void initState() {
  super.initState();
  WidgetsBinding.instance.addObserver(this);
  _loadPinState();
  showDailyReminder();
}
Future<void> _loadPinState() async {
  final enabled = (await PosDb.instance.setting('owner_pin_enabled') ?? 'true') == 'true';
  if (!mounted) return;
  setState(() {
    pinEnabled = enabled;
    unlocked = !enabled;
  });
}
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
    Future<void> showDailyReminder() async {
  final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

  final lastShown =
      await PosDb.instance.setting('daily_popup_last_date');

  if (lastShown == today || !mounted) return;

  await PosDb.instance.setSetting(
    'daily_popup_last_date',
    today,
  );

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (!mounted) return;

    final soundEnabled =
        (await PosDb.instance.setting('closing_sound') ?? 'true') ==
            'true';

    if (soundEnabled) {
      await SystemSound.play(SystemSoundType.alert);
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(
          Icons.notifications_active,
          size: 52,
          color: Colors.teal,
        ),
        title: const Text(
          'PENGINGAT HARIAN',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 22,
          ),
        ),
        content: const Text(
          'JANGAN LUPA ABSEN TERLEBIH DAHULU !\n\n'
          'TOLONG SEMUA BARANG DISCAN',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('SAYA MENGERTI'),
            ),
          ),
        ],
      ),
    );
  });
    }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      if (mounted && pinEnabled && unlocked) setState(() => unlocked = false);
    }
  }
  Future<String?> _pinDialog(String title, {bool allowCancel = true}) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(context: context, barrierDismissible: allowCancel, builder: (ctx) =>
      AlertDialog(title: Text(title), content: TextField(controller: controller, autofocus: true,
        keyboardType: TextInputType.number, obscureText: true, maxLength: 8,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'PIN 4–8 digit')),
        actions: [
          if (allowCancel) TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Lanjutkan')),
        ]));
    controller.dispose();
    return result;
  }
  Future<bool> unlock() async {
    if (unlocked) return true;
    final pinIsEnabled = (await PosDb.instance.setting('owner_pin_enabled') ?? 'true') == 'true';
    if (!pinIsEnabled) {
      if (mounted) setState(() {
        pinEnabled = false;
        unlocked = true;
      });
      return true;
    }
    final existing = await PosDb.instance.setting('pin_hash');
    if (existing == null) {
      final pin = await _pinDialog('Buat PIN pemilik (pertama kali)', allowCancel: true);
      if (pin == null) return false;
      if (pin.length < 4 || pin.length > 8) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN harus 4–8 digit.')));
        return false;
      }
      final confirm = await _pinDialog('Ulangi PIN pemilik');
      if (confirm != pin) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN tidak sama. Coba lagi.')));
        return false;
      }
      await PosDb.instance.setPin(pin);
      if (mounted) setState(() => unlocked = true);
      return true;
    }
    final pin = await _pinDialog('PIN pemilik');
    if (pin == null) return false;
    final ok = await PosDb.instance.verifyPin(pin);
    if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN salah.')));
    if (ok && mounted) setState(() {
      pinEnabled = true;
      unlocked = true;
    });
    return ok;
  }
  @override Widget build(BuildContext context) {
    final pages = [
      CashierPage(key: _cashierKey, showPrivate: unlocked, requestUnlock: unlock),
      ProductsPage(showPrivate: unlocked, requestUnlock: unlock),
      TransactionsPage(showPrivate: unlocked, requestUnlock: unlock),
      SettingsPage(
        onLock: () => setState(() => unlocked = false),
        requestUnlock: unlock,
        onPinStateChanged: (enabled) => setState(() {
          pinEnabled = enabled;
          unlocked = !enabled;
        }),
      ),
    ];
    return WillPopScope(
      onWillPop: () async {
        final shouldExit = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Keluar dari Rabay Cell?'),
            content: const Text('Apakah Anda yakin ingin keluar dari aplikasi?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('BATAL'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('YA, KELUAR'),
              ),
            ],
          ),
        );
        return shouldExit ?? false;
      },
      child: Scaffold(
      appBar: AppBar(title: Row(children: [
        Container(width: 38, height: 38, padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: const Color(0xFF008F83), borderRadius: BorderRadius.circular(10)), child: Image.asset('assets/rabay_logo.png', fit: BoxFit.contain)),
        const SizedBox(width: 10), const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('RABAY CELL', style: TextStyle(fontWeight: FontWeight.w800)), Text('SEMANGAT! Scan Terus', style: TextStyle(fontSize: 11, fontWeight: FontWeight.normal))]))
      ]),
        actions: [IconButton(tooltip: unlocked ? 'Kunci informasi pemilik' : 'Buka informasi pemilik',
          icon: Icon(unlocked ? Icons.visibility_off : Icons.lock_outline),
          onPressed: () async { if (unlocked) { setState(() => unlocked = false); } else { await unlock(); } })]),
      body: ColoredBox(
        color: const Color(0xFFF3FAF9),
        child: IndexedStack(index: tab, children: pages),
      ),
      bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) async {
        if (i == 3 && !unlocked) {
          final ok = await unlock();
          if (!ok) return;
        }
        if (mounted) setState(() => tab = i);
        if (i == 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _cashierKey.currentState?.focusBarcode();
          });
        }
      },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.point_of_sale_outlined), selectedIcon: Icon(Icons.point_of_sale), label: 'Kasir'),
          NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Barang'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Transaksi'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Pengaturan'),
        ]),
      ),
    );
  }
}

class CashierPage extends StatefulWidget {
  final bool showPrivate;
  final Future<bool> Function() requestUnlock;
  const CashierPage({super.key, required this.showPrivate, required this.requestUnlock});
  @override State<CashierPage> createState() => _CashierPageState();
}
class _CashierPageState extends State<CashierPage> {
  final scan = TextEditingController();
  final paid = TextEditingController();
  final focus = FocusNode();
  final List<CartLine> cart = [];
  String search = '';
  @override void initState() { super.initState(); _restoreCart(); }
  Future<void> _restoreCart() async {
    final saved = await PosDb.instance.loadCart();
    if (!mounted || saved == null) return;
    final items = <CartLine>[];
    for (final x in (saved['items'] as List? ?? []).whereType<Map>()) {
      final productId = x['productId'] as int;
      final product = await PosDb.instance.productById(productId);
      items.add(CartLine(
        productId: productId,
        name: x['name'] as String,
        barcode: x['barcode'] as String,
        imageData: product?['image_data'] as Uint8List?,
        cost: x['cost'] as int,
        price: x['price'] as int,
        qty: x['qty'] as int,
      ));
    }
    if (!mounted) return;
    setState(() { cart..clear()..addAll(items); paid.text = saved['paid'] as String? ?? ''; });
  }
  Future<void> _persistCart() => PosDb.instance.saveCart(cart, paid.text);
  void focusBarcode() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) focus.requestFocus();
    });
  }
  void _cartChanged(VoidCallback change) { setState(change); _persistCart(); }
  int get total => cart.fold(0, (s, x) => s + x.subtotal);
  @override void dispose() { scan.dispose(); paid.dispose(); focus.dispose(); super.dispose(); }
  Future<void> addBarcode(String value) async {
    final code = value.trim();
    if (code.isEmpty) return;
    final product = await PosDb.instance.productByBarcode(code);
    scan.clear();
    if (product == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Barcode "$code" tidak ditemukan.')));
      return;
    }
    final id = product['id'] as int;
    final existing = cart.where((x) => x.productId == id).toList();
    _cartChanged(() {
      if (existing.isNotEmpty) {
        final line = existing.first;
        line.qty++;
        cart.remove(line);
        cart.insert(0, line);
      } else {
        cart.insert(0, CartLine(productId: id, name: product['name'] as String, barcode: product['barcode'] as String,
          imageData: product['image_data'] as Uint8List?, cost: product['cost'] as int, price: product['price'] as int));
      }
    });
    focus.requestFocus();
  }
  Future<void> chooseProduct() async {
    // Lepaskan fokus dari input barcode saat membuka pencarian.
    // Ini mencegah keyboard/scanner kembali mengambil fokus ketika
    // pengguna mengetik di kolom pencarian.
    focus.unfocus();

    final all = await PosDb.instance.products();
    if (!mounted) return;

    final selected = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        String query = '';

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final q = query.trim().toLowerCase();

            final filtered = q.isEmpty
                ? all
                : all.where((x) {
                    final name =
                        (x['name']?.toString() ?? '').toLowerCase();
                    final code =
                        (x['code']?.toString() ?? '').toLowerCase();
                    final barcode =
                        (x['barcode']?.toString() ?? '').toLowerCase();
                    final category =
                        (x['category']?.toString() ?? '').toLowerCase();

                    return name.contains(q) ||
                        code.contains(q) ||
                        barcode.contains(q) ||
                        category.contains(q);
                  }).toList();

            return SafeArea(
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * .75,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Cari nama, kode, barcode',
                        ),
                        onChanged: (v) {
                          setSheetState(() => query = v);
                        },
                      ),
                    ),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text('Barang tidak ditemukan'),
                            )
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (_, i) {
                                final x = filtered[i];

                                return ListTile(
                                  title: Text('${x['name']}'),
                                  subtitle: Text(
                                    'Kode: ${x['code']} • Stok: ${x['stock']}',
                                  ),
                                  trailing: Text(
                                    money.format(x['price']),
                                  ),
                                  onTap: () =>
                                      Navigator.pop(ctx, x),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (selected != null) {
      await addBarcode(selected['barcode'] as String);
    } else {
      // Jika pencarian dibatalkan, kembalikan fokus barcode agar
      // scanner USB/Bluetooth siap digunakan lagi.
      focusBarcode();
    }
  }
  
Future<void> finishSale() async {
  final amount =
      int.tryParse(paid.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  // Simpan nilai sebelum keranjang dikosongkan
  final saleTotal = total;

  try {
    await PosDb.instance.checkout(cart, amount);

    if (!mounted) return;

    setState(() {
      cart.clear();
      paid.clear();
    });

    await _persistCart();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transaksi berhasil'),
        content: Text(
          'Total: ${money.format(saleTotal)}\n'
          'Kembalian: ${money.format(amount - saleTotal)}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Selesai'),
          ),
        ],
      ),
    );
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
          ),
        ),
      );
    }
  }
}

  @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(8, 16, 8, 2), child: Column(children: [
    TextField(controller: scan, focusNode: focus, autofocus: true,
      decoration: const InputDecoration(prefixIcon: Icon(Icons.qr_code_scanner), labelText: 'Scan barcode lalu tekan Enter',
        hintText: 'Scanner USB/Bluetooth atau ketik kode'),
      onSubmitted: addBarcode),
    const SizedBox(height: 12),
    Row(children: [Expanded(child: Text('Keranjang', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
      Text('${cart.length} jenis barang')]),
    const SizedBox(height: 8),
    Expanded(child: cart.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.shopping_cart_outlined, size: 54, color: Colors.grey.shade400),
      const SizedBox(height: 8), const Text('Scan barcode untuk mulai transaksi'),
      const SizedBox(height: 12), OutlinedButton.icon(onPressed: chooseProduct, icon: const Icon(Icons.search), label: const Text('Cari barang')),
    ])) : ListView.separated(itemCount: cart.length, separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final line = cart[i];
        return Card(
          color: i == 0 ? const Color(0xFFE5EFEE) : Colors.white,
          margin: EdgeInsets.zero,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7), child: Row(children: [
            _productThumbnail(line.imageData, size: 44),
            const SizedBox(width: 7),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(line.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${money.format(line.price)} × ${line.qty}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
              if (widget.showPrivate) Text('Untung: ${money.format((line.price-line.cost)*line.qty)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.green, fontSize: 10)),
            ])),
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
              onPressed: () async {
                if (line.qty > 1) {
                  _cartChanged(() => line.qty--);
                  return;
                }
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Hapus dari keranjang?'),
                    content: Text('Hapus "${line.name}" dari keranjang?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Batal')),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Hapus'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) _cartChanged(() => cart.remove(line));
              },
              icon: const Icon(Icons.remove_circle_outline, size: 21),
            ),
            Text('${line.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
            IconButton(visualDensity: VisualDensity.compact, constraints: const BoxConstraints(minWidth: 34, minHeight: 34), padding: EdgeInsets.zero, onPressed: () => _cartChanged(() { line.qty++; cart.remove(line); cart.insert(0, line); }), icon: const Icon(Icons.add_circle_outline, size: 21)),

          ])));
      })),
    Card(
      margin: EdgeInsets.zero,
      child: Padding(
        // Dipadatkan agar kartu tidak memakan banyak ruang vertikal,
        // sekaligus memberi ruang lebih lebar di kiri/kanan.
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
        child: Column(children: [
          Row(children: [
            const Expanded(child: Text('Total', style: TextStyle(fontSize: 16))),
            Text(money.format(total), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          ]),
          if (widget.showPrivate)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Estimasi untung: ${money.format(cart.fold<int>(0, (s, x) => s + (x.price-x.cost)*x.qty))}',
                style: const TextStyle(color: Colors.green),
              ),
            ),
          const SizedBox(height: 7),
          TextField(
            controller: paid,
            onChanged: (_) => _persistCart(),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.payments_outlined),
              labelText: 'Uang diterima (Rp)',
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: chooseProduct,
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Tambah barang', maxLines: 1, softWrap: false, style: TextStyle(fontSize: 11)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: cart.isEmpty ? null : finishSale,
                icon: const Icon(Icons.check_circle_outline, size: 20),
                label: const Text('Bayar'),
              ),
            ),
          ]),
        ]),
      ),
    ),
  ]));
}

class ProductsPage extends StatefulWidget {
  final bool showPrivate;
  final Future<bool> Function() requestUnlock;
  const ProductsPage({super.key, required this.showPrivate, required this.requestUnlock});
  @override State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  final search = TextEditingController();
  String productFilter = 'A–Z';
  String selectedCategory = 'Semua kategori';

  Future<void> refresh() async { if (mounted) setState(() {}); }
  Future<void> editProduct([Map<String, Object?>? item]) async {
    if (!(widget.showPrivate || await widget.requestUnlock())) return;
    final name = TextEditingController(text: item?['name'] as String? ?? '');
    final code = TextEditingController(text: item?['code'] as String? ?? '');
    final barcode = TextEditingController(text: item?['barcode'] as String? ?? '');
    final cost = TextEditingController(text: item?['cost']?.toString() ?? '');
    final price = TextEditingController(text: item?['price']?.toString() ?? '');
    final stock = TextEditingController(text: item?['stock']?.toString() ?? '0');
    final category = TextEditingController(text: item?['category'] as String? ?? '');
    Uint8List? imageData = item?['image_data'] as Uint8List?;
    final existingCategories = await PosDb.instance.categories();
    const newCategoryOption = '＋ Kategori baru';
    String selectedCategoryValue = existingCategories.contains(category.text.trim())
        ? category.text.trim()
        : newCategoryOption;
    final key = GlobalKey<FormState>();
    final saved = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) => AlertDialog(
      title: Row(children: [
        Expanded(child: Text(item == null ? 'Tambah barang' : 'Edit barang')),
        if (item != null) IconButton(
          tooltip: 'Hapus barang',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.delete_outline, color: Colors.red, size: 23),
          onPressed: () async {
            final confirm = await showDialog<bool>(context: ctx, builder: (confirmCtx) => AlertDialog(
              title: const Text('Hapus barang?'),
              content: Text('Barang "${item['name']}" akan dihapus dari daftar stok. Riwayat transaksi sebelumnya tetap tersimpan. Tindakan ini tidak dapat dibatalkan.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(confirmCtx, false), child: const Text('Batal')),
                FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(confirmCtx, true), child: const Text('Hapus barang')),
              ],
            ));
            if (confirm != true) return;
            try {
              await PosDb.instance.deleteProduct(item['id'] as int);
              if (ctx.mounted) Navigator.pop(ctx, false);
              if (mounted) {
                await refresh();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Barang berhasil dihapus.')));
              }
            } catch (e) {
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal menghapus barang: $e')));
            }
          },
        ),
      ]),
      content: SizedBox(width: 480, child: SingleChildScrollView(child: Form(key: key, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          _productThumbnail(imageData, size: 58),
          const SizedBox(width: 12),
          Expanded(child: OutlinedButton.icon(
            onPressed: () async {
              try {
                Uint8List? bytes;
                bytes = await _photoPickerChannel.invokeMethod<Uint8List>('pickImageBytes');
                if (bytes == null || bytes!.isEmpty) {
                  throw Exception('File gambar tidak dapat dibaca sebagai data aplikasi.');
                }
                // Hanya byte gambar yang disimpan ke SQLite privat aplikasi.
                // Tidak ada fallback FilePicker dan aplikasi tidak menyalin gambar ke Pictures/DCIM.
                setDialogState(() => imageData = bytes);
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal memilih foto: $e')));
              }
            },
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('Pilih foto barang'),
          )),
          if (imageData != null && imageData!.isNotEmpty) IconButton(
            tooltip: 'Hapus foto', icon: const Icon(Icons.close),
            onPressed: () => setDialogState(() => imageData = null),
          ),
        ]),
        const SizedBox(height: 12),
        _field(name, 'Nama barang'), _field(code, 'Kode barang'), _field(barcode, 'Barcode'),
        DropdownButtonFormField<String>(
          value: selectedCategoryValue,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Pilih kategori'),
          items: [...existingCategories.map((c) => DropdownMenuItem(value: c, child: Text(c))),
            const DropdownMenuItem(value: newCategoryOption, child: Text('＋ Kategori baru'))],
          onChanged: (value) {
            if (value == null) return;
            setDialogState(() {
              selectedCategoryValue = value;
              if (value != newCategoryOption) category.text = value;
              else category.clear();
            });
          },
        ),
        if (selectedCategoryValue == newCategoryOption)
          _field(category, 'Nama kategori baru (contoh: Pulsa, Aksesoris)'),
        const SizedBox(height: 8),
        _field(cost, 'Harga modal (Rp)', numeric: true), _field(price, 'Harga jual (Rp)', numeric: true),
        _field(stock, 'Stok', numeric: true),
      ])))),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        FilledButton(onPressed: () {
          if (key.currentState!.validate()) Navigator.pop(ctx, true);
        }, child: const Text('Simpan'))],
    )));
    if (saved == true) {
      try {
        await PosDb.instance.saveProduct(id: item?['id'] as int?, name: name.text, code: code.text, barcode: barcode.text,
          cost: int.parse(cost.text), price: int.parse(price.text), stock: int.parse(stock.text),
          category: selectedCategoryValue == newCategoryOption ? category.text : selectedCategoryValue,
          imageData: imageData);
        await refresh();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal menyimpan. Pastikan kode dan barcode unik. $e')));
      }
    }
  }
  Widget _field(TextEditingController c, String label, {bool numeric = false}) => Padding(padding: const EdgeInsets.only(bottom: 10),
    child: TextFormField(controller: c, keyboardType: numeric ? TextInputType.number : TextInputType.text,
      inputFormatters: numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
      validator: (v) => v == null || v.trim().isEmpty ? 'Wajib diisi' : null, decoration: InputDecoration(labelText: label)));
  @override Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFFF3FAF9),
    child: Column(children: [
    FutureBuilder<List<Map<String, Object?>>>(future: PosDb.instance.products(), builder: (ctx, snap) {
      if (!snap.hasData) return const SizedBox(height: 88, child: Center(child: CircularProgressIndicator()));
      final all = snap.data!;
      final capital = all.fold<int>(0, (sum, x) => sum + (x['cost'] as int) * (x['stock'] as int));
      return Card(margin: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [
        Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFFE0F5F2), borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.account_balance_wallet_outlined, color: Color(0xFF008F83), size: 26)),
        const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Total modal semua barang', style: TextStyle(fontSize: 12)), const SizedBox(height: 3), Text(widget.showPrivate ? money.format(capital) : '••••••••', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)), Text(widget.showPrivate ? '${all.length} jenis barang' : 'Buka melalui tombol gembok di atas', style: TextStyle(fontSize: 11, color: Colors.grey.shade600))])),
const SizedBox.shrink()
      ])));
    }),
    Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: Row(children: [
      Expanded(child: TextField(controller: search, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Cari barang...'))),
      const SizedBox(width: 8), FilledButton.icon(onPressed: () => editProduct(), icon: const Icon(Icons.add), label: const Text('Tambah')),
    ])),
      
Padding(
  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
  child: Row(
    children: [
      FutureBuilder<List<String>>(
        future: PosDb.instance.categories(),
        builder: (ctx, snap) {
          final categories = ['Semua kategori', ...?snap.data];
          if (!categories.contains(selectedCategory)) selectedCategory = 'Semua kategori';
          return Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.black12)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: selectedCategory,
                isDense: true,
                hint: const Text('Kategori'),
                style: const TextStyle(fontSize: 11, color: Colors.black87),
                items: categories.map((c) => DropdownMenuItem<String>(value: c, child: SizedBox(width: 105, child: Text(c, maxLines: 1, overflow: TextOverflow.ellipsis)))).toList(),
                onChanged: (v) => setState(() => selectedCategory = v ?? 'Semua kategori'),
              ),
            ),
          );
        },
      ),
      const SizedBox(width: 5),
      Expanded(
        child: Row(
          children: ['A–Z', 'Termurah', 'Stok'].map((filter) {
            final selected = productFilter == filter;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 1),
                  label: SizedBox(
                    width: double.infinity,
                    child: Text(filter, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.clip,
                      style: TextStyle(fontSize: 11, color: selected ? Colors.white : Colors.black87, fontWeight: FontWeight.w600)),
                  ),
                  selected: selected,
                  selectedColor: const Color(0xFF008577),
                  onSelected: (_) => setState(() => productFilter = filter),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    ],
  ),
),

    Expanded(child: FutureBuilder<List<Map<String, Object?>>>(future: PosDb.instance.products(query: search.text), builder: (ctx, snap) {
      if (snap.hasError) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Gagal memuat barang:\n${snap.error}',
        textAlign: TextAlign.center,
      ),
    ),
  );
}

if (!snap.hasData) {
  return const Center(
    child: CircularProgressIndicator(),
  );
}
      final items = List<Map<String, Object?>>.from(snap.data!);
      if (selectedCategory != 'Semua kategori') {
        items.removeWhere((x) => (x['category'] as String? ?? '').trim() != selectedCategory);
      }

if (productFilter == 'Termurah') {
  items.sort((a, b) =>
      ((a['price'] as num?) ?? 0)
          .compareTo((b['price'] as num?) ?? 0));
} else if (productFilter == 'Stok') {
  // Tampilkan semua barang, dari stok paling sedikit ke paling banyak.
  items.sort((a, b) =>
      ((a['stock'] as num?) ?? 0)
          .compareTo((b['stock'] as num?) ?? 0));
} else {
  items.sort((a, b) =>
      ('${a['name'] ?? ''}')
          .toLowerCase()
          .compareTo(('${b['name'] ?? ''}').toLowerCase()));
}

if (items.isEmpty) {
  return const Center(
    child: Text('Belum ada barang yang cocok dengan pencarian.'),
  );
}

return ColoredBox(
  color: const Color(0xFFF3FAF9),
  child: ListView(
  padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
  children: items.map((x) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => editProduct(x),
        child: Padding(
          padding: const EdgeInsets.only(
            left: 10,
            right: 14,
            top: 5,
            bottom: 5,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _productThumbnail(x['image_data'] as Uint8List?, size: 56),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${x['name'] ?? '-'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.0,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 0),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Modal: ${widget.showPrivate ? money.format(x['cost'] ?? 0) : '••••••'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              height: 1.0,
                              color: Colors.black54,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            money.format(x['price'] ?? 0),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.0,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF008577),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
  'Update : ${safeDateFormat(x['updated_at'])}',
  style: const TextStyle(fontSize: 10, height: 1.0, color: Colors.black54),
  ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'STOK:',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.0,
                      color: Colors.black54,
                    ),
                  ),
                  Text(
                    '${x['stock'] ?? 0}',
                    style: const TextStyle(
                      fontSize: 28,
                      height: 1.0,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF008577),
                    ),
                  ),
                  const Icon(
                    Icons.edit_outlined,
                    size: 12,
                    color: Colors.black45,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }).toList(),
  ),
);

    })),
  ]),
  );
}

class TransactionsPage extends StatefulWidget {
  final bool showPrivate;
  final Future<bool> Function() requestUnlock;
  const TransactionsPage({super.key, required this.showPrivate, required this.requestUnlock});
  @override State<TransactionsPage> createState() => _TransactionsPageState();
}
class _TransactionsPageState extends State<TransactionsPage> {
  Future<void> openDetail(Map<String, Object?> tx) async {
    final id = tx['id'] as int;
    final items = await PosDb.instance.items(id);
    final logs = await PosDb.instance.audit(id);
    if (!mounted) return;
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Text('Transaksi #$id'),
      content: SizedBox(width: 500, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('Tanggal & waktu: ${safeDateFormat(tx['created_at'])}'),
        Text('Status: ${(tx['status'] as String? ?? 'completed') == 'cancelled' ? 'DIBATALKAN' : 'Selesai'}', style: TextStyle(color: (tx['status'] as String? ?? 'completed') == 'cancelled' ? Colors.red : Colors.green, fontWeight: FontWeight.bold)),
        if ((tx['updated_at']?.toString().trim() ?? '').isNotEmpty) Text('DIUBAH: ${safeDateFormat(tx['updated_at'])}', style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold)),
        const Divider(),

...items.map((x) {
  final itemCancelled = (x['cancelled'] as int? ?? 0) == 1;
  final transactionCancelled =
      (tx['status'] as String? ?? 'completed') == 'cancelled';

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${x['product_name']} × ${x['qty']}'
                '${itemCancelled ? ' • DIBATALKAN' : ''}',
                style: TextStyle(
                  color: itemCancelled ? Colors.red : null,
                  decoration:
                      itemCancelled ? TextDecoration.lineThrough : null,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              money.format(
                (x['price_snapshot'] as int) * (x['qty'] as int),
              ),
              style: TextStyle(
                color: itemCancelled ? Colors.grey : null,
                decoration:
                    itemCancelled ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
        if (!itemCancelled && !transactionCancelled)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (confirmCtx) => AlertDialog(
                    title: const Text('Batalkan barang?'),
                    content: Text(
                      'Barang ${x['product_name']} akan dibatalkan '
                      'dan stoknya dikembalikan.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            Navigator.pop(confirmCtx, false),
                        child: const Text('Kembali'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () =>
                            Navigator.pop(confirmCtx, true),
                        child: const Text('Ya, batalkan'),
                      ),
                    ],
                  ),
                );

                if (confirm != true) return;

                try {
                  await PosDb.instance.cancelTransactionItem(
                    x['id'] as int,
                  );

                  if (!mounted) return;

                  Navigator.of(ctx).pop();
                  setState(() {});

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Barang dibatalkan dan stok dikembalikan.',
                      ),
                    ),
                  );
                } catch (e) {
                  if (!mounted) return;

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Gagal membatalkan barang: $e'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: const Text('BATAL'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.red,
              ),
            ),
          ),
        const Divider(height: 12),
      ],
    ),
  );
}),
        const Divider(),
        Text('Total: ${money.format(tx['total'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
        if (widget.showPrivate) Text('Modal: ${money.format(items.fold<int>(0, (s, x) => s + (x['cost_snapshot'] as int)*(x['qty'] as int)))}'),
        if (widget.showPrivate) Text('Keuntungan: ${money.format(tx['profit'])}', style: const TextStyle(color: Colors.green)),
        Text('Dibayar: ${money.format(tx['paid'])}'),
        Text('Kembalian: ${money.format(tx['change_amount'])}'),
        if (logs.isNotEmpty) ...[
          const Divider(), const Text('Riwayat perubahan', style: TextStyle(fontWeight: FontWeight.bold)),
          ...logs.map(
  (x) => Text(
    "${safeDateFormat(x['changed_at'])}\n"
    "Total ${money.format(x['old_total'])} → "
    "${money.format(x['new_total'])}",
  ),
),
        ],
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tutup')),
        if ((tx['status'] as String? ?? 'completed') != 'cancelled') ...[
          OutlinedButton.icon(onPressed: () async {
            if (!(widget.showPrivate || await widget.requestUnlock())) return;
            final confirm = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Batalkan transaksi?'), content: const Text('Stok barang akan dikembalikan. Transaksi tetap tersimpan di riwayat dan tidak dihitung dalam omzet/keuntungan.'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Tidak')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Ya, batalkan'))]));
            if (confirm == true) { Navigator.pop(ctx); try { await PosDb.instance.cancelTransaction(id); if (mounted) setState(() {}); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()))); } }
          }, icon: const Icon(Icons.cancel_outlined), label: const Text('Batalkan')),
          FilledButton.icon(onPressed: () async { Navigator.pop(ctx); if (widget.showPrivate || await widget.requestUnlock()) await editTx(tx); }, icon: const Icon(Icons.edit), label: const Text('Ubah transaksi')),
        ],
      ],
    ));
  }

  Future<void> editTx(Map<String, Object?> tx) async {
    final id = tx['id'] as int;
    final oldItems = await PosDb.instance.items(id);
    final cart = <CartLine>[];
    for (final item in oldItems) {
      final productId = item['product_id'] as int?;
      if (productId == null) continue;
      final product = await PosDb.instance.db.query('products', where: 'id = ?', whereArgs: [productId], limit: 1);
      if (product.isEmpty) continue;
      cart.add(CartLine(productId: productId, name: item['product_name'] as String,
        barcode: item['barcode'] as String, cost: item['cost_snapshot'] as int,
        price: item['price_snapshot'] as int, qty: item['qty'] as int));
    }
    final paid = TextEditingController(text: tx['paid'].toString());
    if (!mounted) return;
    final result = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
      final total = cart.fold<int>(0, (s, x) => s+x.subtotal);
      return AlertDialog(title: Text('Ubah transaksi #$id'), content: SizedBox(width: 500, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Perubahan akan dicatat dengan tanggal dan waktu. Stok akan disesuaikan otomatis.'),
        ...cart.asMap().entries.map((entry) => ListTile(title: Text(entry.value.name), subtitle: Text('${money.format(entry.value.price)} × ${entry.value.qty}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(onPressed: () => setLocal(() { if (entry.value.qty > 1) entry.value.qty--; else cart.removeAt(entry.key); }), icon: const Icon(Icons.remove_circle_outline)),
            Text('${entry.value.qty}'),
            IconButton(onPressed: () => setLocal(() => entry.value.qty++), icon: const Icon(Icons.add_circle_outline)),
          ]))),
        OutlinedButton.icon(onPressed: () async {
          final products = await PosDb.instance.products();
          if (!ctx.mounted) return;
          final selected = await showModalBottomSheet<Map<String, Object?>>(context: ctx, builder: (c) => ListView(
            children: products.map((x) => ListTile(title: Text('${x['name']}'), subtitle: Text('Stok ${x['stock']}'),
              trailing: Text(money.format(x['price'])), onTap: () => Navigator.pop(c, x))).toList()));
          if (selected != null) setLocal(() => cart.add(CartLine(productId: selected['id'] as int,
            name: selected['name'] as String, barcode: selected['barcode'] as String,
            cost: selected['cost'] as int, price: selected['price'] as int)));
        }, icon: const Icon(Icons.add), label: const Text('Tambah barang')),
        const SizedBox(height: 8), Text('Total baru: ${money.format(total)}', style: const TextStyle(fontWeight: FontWeight.bold)),
        TextField(controller: paid, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Uang diterima (Rp)')),
      ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Simpan perubahan'))],
    );}));
    if (result == true) {
      try {
        await PosDb.instance.editTransaction(id, cart, int.tryParse(paid.text) ?? 0);
        if (mounted) { setState(() {}); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Transaksi diperbarui dan tercatat di audit.'))); }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  @override Widget build(BuildContext context) => FutureBuilder<List<Map<String, Object?>>>(
    future: PosDb.instance.transactions(), builder: (ctx, snap) {
      if (snap.hasError) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Gagal memuat transaksi. Coba buka kembali halaman ini.\n${snap.error}',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      if (!snap.hasData) return const Center(child: CircularProgressIndicator());
      final list = List<Map<String, Object?>>.from(snap.data!);

list.sort((a, b) {
  final dateA = safeDateTime(a['created_at']);
  final dateB = safeDateTime(b['created_at']);
  return dateB.compareTo(dateA);
});

final activeList = list.where(
  (x) => (x['status'] as String? ?? 'completed') != 'cancelled',
).toList();

final totalSales = activeList.fold<int>(
  0, (s, x) => s + (x['total'] as int),
);
      final totalProfit = activeList.fold<int>(0, (s, x) => s + (x['profit'] as int));
      return ColoredBox(
        color: const Color(0xFFF3FAF9),
        child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Row(children: [
          
Expanded(
  child: FilledButton.icon(
    onPressed: () async {
      if (!(widget.showPrivate || await widget.requestUnlock())) return;
      final titleController = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Tutup sesi / jumlahkan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Transaksi pada sesi ini akan dijumlahkan dan diarsipkan. Sesi baru akan dimulai.'),
              const SizedBox(height: 14),
              TextField(
                controller: titleController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Judul sesi',
                  hintText: 'Contoh: Shift pagi / Setoran mingguan',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Tutup sesi')),
          ],
        ),
      );

      if (ok == true) {
        final sessionTitle = titleController.text.trim();
        titleController.dispose();
        final result = await PosDb.instance.closeSession(title: sessionTitle);
        if (mounted) setState(() {});
        if (!mounted) return;
        final dateRange = '${sessionDateFormat(result['started_at'])} - ${sessionDateFormat(result['closed_at'])}';
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(sessionTitle.isEmpty ? 'Sesi #${result['id']} diarsipkan' : '"$sessionTitle" diarsipkan'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dateRange, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                const SizedBox(height: 8),
                Text('${result['transaction_count']} transaksi', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('Omzet: ${money.format(result['total_sales'])}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text('Keuntungan: ${money.format(result['total_profit'])}'),
              ],
            ),
            actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Selesai'))],
          ),
        );
      } else {
        titleController.dispose();
      }
    },
    icon: const Icon(Icons.archive_outlined),
    label: const Text('Jumlahkan & tutup sesi'),
  ),
),

          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () async {
              if (!(widget.showPrivate || await widget.requestUnlock())) return;
              try {
                final sessions = await PosDb.instance.sessions();
                if (!mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Arsip sesi'),
                    content: SizedBox(
                      width: double.maxFinite,
                      height: 420,
                      child: sessions.isEmpty
                          ? const Center(child: Text('Belum ada sesi yang diarsipkan.'))
                          : ListView.builder(
                              itemCount: sessions.length,
                              itemBuilder: (context, index) {
                                final ss = sessions[index];
                                final storedTitle = (ss['title'] as String? ?? '').trim();
                                final archiveTitle = storedTitle.isEmpty ? 'Sesi #${ss['id']}' : storedTitle;
                                return Card(
                                  color: Colors.white,
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    dense: true,
                                    title: Text(archiveTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text('${sessionDateFormat(ss['started_at'])} - ${sessionDateFormat(ss['closed_at'])}', style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
                                        const SizedBox(height: 3),
                                        Row(children: [
                                          Text('${ss['transaction_count']} transaksi', style: const TextStyle(fontSize: 12)),
                                          const Spacer(),
                                          Text(money.format(ss['total_sales'] ?? 0), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                        ]),
                                      ],
                                    ),
                                    trailing: IconButton(
                                          tooltip: 'Hapus baris arsip ini',
                                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                                          onPressed: () async {
                                            final archiveId = ss['id'] as int;
                                            final confirm = await showDialog<bool>(
                                              context: dialogContext,
                                              builder: (confirmContext) => AlertDialog(
                                                title: const Text('Hapus arsip sesi?'),
                                                content: Text(
                                                  'Sesi #$archiveId beserta seluruh riwayat transaksinya akan dihapus permanen. '
                                                  'Stok barang tidak berubah. Tindakan ini tidak dapat dibatalkan.',
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () => Navigator.pop(confirmContext, false),
                                                    child: const Text('Batal'),
                                                  ),
                                                  FilledButton(
                                                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                                    onPressed: () => Navigator.pop(confirmContext, true),
                                                    child: const Text('Hapus arsip'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm != true) return;
                                            try {
                                              await PosDb.instance.deleteArchivedSession(archiveId);
                                              if (!dialogContext.mounted) return;
                                              Navigator.pop(dialogContext);
                                              if (mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(content: Text('Arsip sesi #$archiveId dan riwayatnya dihapus.')),
                                                );
                                              }
                                            } catch (e) {
                                              if (dialogContext.mounted) {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  SnackBar(content: Text('Gagal menghapus arsip: $e')),
                                                );
                                              }
                                            }
                                          },
                                    ),
                                    onTap: () async {
                                      try {
                                        final txs = await PosDb.instance.sessionTransactions(ss['id'] as int);
                                        if (!dialogContext.mounted) return;
                                        await showDialog<void>(
                                          context: dialogContext,
                                          builder: (detailContext) => AlertDialog(
                                            title: Text('Riwayat $archiveTitle'),
                                            content: SizedBox(
                                              width: double.maxFinite,
                                              height: 420,
                                              child: ListView(
                                                children: [
                                                  Text('Omzet: ${money.format(ss['total_sales'] ?? 0)}'),
                                                  Text('Keuntungan: ${money.format(ss['total_profit'] ?? 0)}'),
                                                  const Divider(),
                                                  if (txs.isEmpty) const Text('Tidak ada transaksi pada sesi ini.'),
                                                  ...txs.map((t) => ListTile(
                                                    contentPadding: EdgeInsets.zero,
                                                    title: Text('Transaksi #${t['id']}'),
                                                    subtitle: Text(
                                                      '${safeDateFormat(t['created_at'])} • '
                                                      '${(t['status'] as String? ?? 'completed') == 'cancelled' ? 'DIBATALKAN' : 'Selesai'}',
                                                    ),
                                                    trailing: Row(
                                                      mainAxisSize: MainAxisSize.min,
                                                      children: [
                                                        Text(money.format(t['total'] ?? 0)),
                                                        IconButton(
                                                          tooltip: 'Hapus transaksi arsip',
                                                          icon: const Icon(Icons.delete_outline, color: Colors.red),
                                                          onPressed: () async {
                                                            final confirm = await showDialog<bool>(
                                                              context: detailContext,
                                                              builder: (confirmContext) => AlertDialog(
                                                                title: const Text('Hapus transaksi arsip?'),
                                                                content: Text(
                                                                  'Transaksi #${t['id']} akan dihapus permanen dari riwayat arsip. '
                                                                  'Stok barang tidak berubah. Tindakan ini tidak dapat dibatalkan.',
                                                                ),
                                                                actions: [
                                                                  TextButton(
                                                                    onPressed: () => Navigator.pop(confirmContext, false),
                                                                    child: const Text('Batal'),
                                                                  ),
                                                                  FilledButton(
                                                                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                                                    onPressed: () => Navigator.pop(confirmContext, true),
                                                                    child: const Text('Hapus permanen'),
                                                                  ),
                                                                ],
                                                              ),
                                                            );
                                                            if (confirm != true) return;
                                                            try {
                                                              await PosDb.instance.deleteArchivedTransaction(t['id'] as int);
                                                              if (!detailContext.mounted) return;
                                                              Navigator.pop(detailContext);
                                                              if (dialogContext.mounted) {
                                                                ScaffoldMessenger.of(context).showSnackBar(
                                                                  const SnackBar(content: Text('Transaksi arsip dihapus. Buka kembali Arsip untuk melihat jumlah terbaru.')),
                                                                );
                                                              }
                                                            } catch (e) {
                                                              if (detailContext.mounted) {
                                                                ScaffoldMessenger.of(context).showSnackBar(
                                                                  SnackBar(content: Text('Gagal menghapus transaksi: $e')),
                                                                );
                                                              }
                                                            }
                                                          },
                                                        ),
                                                      ],
                                                    ),
                                                  )),
                                                ],
                                              ),
                                            ),
                                            actions: [TextButton(onPressed: () => Navigator.pop(detailContext), child: const Text('Tutup'))],
                                          ),
                                        );
                                      } catch (e) {
                                        if (dialogContext.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal membuka riwayat sesi: $e')));
                                        }
                                      }
                                    },
                                  ),
                                );
                              },
                            ),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Tutup'))],
                  ),
                );
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal memuat arsip: $e')));
              }
            },
            icon: const Icon(Icons.history),
            label: const Text('Arsip'),
          )
        ])),
        Padding(padding: const EdgeInsets.all(16), child: Row(children: [
          Expanded(child: _stat('Total omzet', money.format(totalSales), Icons.trending_up)),
          const SizedBox(width: 8), Expanded(child: _stat(widget.showPrivate ? 'Total untung' : 'Total untung 🔒',
            widget.showPrivate ? money.format(totalProfit) : '••••••••', Icons.account_balance_wallet_outlined)),
        ])),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('Belum ada transaksi.'))
              : Builder(
                  builder: (context) {
                    final grouped = <String, List<Map<String, Object?>>>{};
                    for (final tx in list) {
                      final dt = safeDateTime(tx['created_at']);
                      final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                      grouped.putIfAbsent(key, () => <Map<String, Object?>>[]).add(tx);
                    }

                    final jakartaNow = DateTime.now().toUtc().add(const Duration(hours: 7));
                    final todayKey = '${jakartaNow.year}-${jakartaNow.month.toString().padLeft(2, '0')}-${jakartaNow.day.toString().padLeft(2, '0')}';
                    final yesterday = jakartaNow.subtract(const Duration(days: 1));
                    final yesterdayKey = '${yesterday.year}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';
                    final dayFmt = DateFormat('dd MMMM yyyy', 'id_ID');
                    final timeFmt = DateFormat('HH:mm');
                    final children = <Widget>[];

                    for (final entry in grouped.entries) {
                      final dt = safeDateTime(entry.value.first['created_at']);
                      final headerDate = dayFmt.format(dt).toUpperCase();
                      final label = entry.key == todayKey
                          ? 'HARI INI • $headerDate'
                          : entry.key == yesterdayKey
                              ? 'KEMARIN • $headerDate'
                              : headerDate;

                      children.add(
                        Padding(
                          padding: const EdgeInsets.only(top: 18, bottom: 8),
                          child: Row(
                            children: [
                              Expanded(child: Divider(color: Colors.teal.shade200, thickness: 1)),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                child: Text(
                                  label,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF007F75),
                                    letterSpacing: .4,
                                  ),
                                ),
                              ),
                              Expanded(child: Divider(color: Colors.teal.shade200, thickness: 1)),
                            ],
                          ),
                        ),
                      );

                      for (final x in entry.value) {
                        final updatedAt = x['updated_at']?.toString().trim() ?? '';
                        final edited = updatedAt.isNotEmpty && updatedAt.toLowerCase() != 'null';
                        final cancelled = (x['status'] as String? ?? 'completed') == 'cancelled';
                        children.add(
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: edited ? Colors.orange.shade50 : Colors.blue.shade50,
                                child: Icon(
                                  edited ? Icons.edit_note : Icons.receipt_long,
                                  color: edited ? Colors.deepOrange : Colors.blue,
                                ),
                              ),
                              title: Text(
                                'Transaksi #${x['id']} • ${money.format(x['total'])}${cancelled ? ' • DIBATALKAN' : ''}',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: cancelled ? Colors.red : null,
                                ),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Jam: ${timeFmt.format(safeDateTime(x['created_at']))}'),
                                  if (edited)
                                    Text(
                                      'Diubah: ${safeDateFormat(x['updated_at'])}',
                                      style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.w600),
                                    ),
                                  if (widget.showPrivate)
                                    Text('Untung: ${money.format(x['profit'])}', style: const TextStyle(color: Colors.green)),
                                ],
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => openDetail(x),
                            ),
                          ),
                        );
                      }
                    }

                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      children: children,
                    );
                  },
                ),
        ),
      ]),
      );
    });
  Widget _stat(String title, String value, IconData icon) => Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Icon(icon, color: Colors.blue), const SizedBox(height: 8), Text(title, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
    const SizedBox(height: 4), Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17), maxLines: 1, overflow: TextOverflow.ellipsis),
  ])));
}

class SettingsPage extends StatefulWidget {
  final VoidCallback onLock;
  final Future<bool> Function() requestUnlock;
  final ValueChanged<bool> onPinStateChanged;
  const SettingsPage({super.key, required this.onLock, required this.requestUnlock, required this.onPinStateChanged});
  @override State<SettingsPage> createState() => _SettingsPageState();
}
class _SettingsPageState extends State<SettingsPage> {
  bool reminderEnabled = true;
  bool pinEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadFeatureFlags();
  }

  Future<void> _loadFeatureFlags() async {
    final alarm = (await PosDb.instance.setting('closing_reminder_enabled') ?? 'true') == 'true';
    final pin = (await PosDb.instance.setting('owner_pin_enabled') ?? 'true') == 'true';
    if (mounted) setState(() { reminderEnabled = alarm; pinEnabled = pin; });
  }

  Future<void> _toggleReminder(bool enabled) async {
    if (!enabled) {
      try {
        await _nativeAlarmChannel.invokeMethod<void>('cancelDailyAlarm');
        await PosDb.instance.setSetting('closing_reminder_enabled', 'false');
        if (mounted) setState(() => reminderEnabled = false);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pengingat harian dimatikan.')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mematikan alarm. Pastikan script alarm terbaru dipasang. $e')));
      }
      return;
    }
    await configureClosingReminder();
    final isEnabled = (await PosDb.instance.setting('closing_reminder_enabled') ?? 'false') == 'true';
    if (mounted) setState(() => reminderEnabled = isEnabled);
  }

  Future<void> _toggleOwnerPin(bool enabled) async {
    if (!enabled) {
      if (!await _requireOwner()) return;
      if (!mounted) return;
      final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Matikan PIN pemilik?'),
        content: const Text('PIN dan salt akan dihapus dari perangkat ini. Informasi modal dan keuntungan tidak lagi dilindungi PIN. Saat diaktifkan kembali, Anda harus membuat PIN baru.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Matikan PIN'))],
      ));
      if (confirm != true) return;
      await PosDb.instance.db.delete('settings', where: 'key IN (?, ?)', whereArgs: ['pin_hash', 'pin_salt']);
      await PosDb.instance.setSetting('owner_pin_enabled', 'false');
      if (mounted) {
        setState(() => pinEnabled = false);
        widget.onPinStateChanged(false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN pemilik dimatikan dan PIN lama dihapus.')));
      }
      return;
    }

    final first = await _askPin('Buat PIN pemilik baru (4–8 digit)');
    if (first == null) return;
    if (first.length < 4 || first.length > 8) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN harus 4–8 digit.')));
      return;
    }
    final second = await _askPin('Ulangi PIN pemilik baru');
    if (second != first) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN tidak sama. Coba lagi.')));
      return;
    }
    await PosDb.instance.setPin(first);
    await PosDb.instance.setSetting('owner_pin_enabled', 'true');
    if (mounted) {
      setState(() => pinEnabled = true);
      widget.onLock();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN pemilik baru berhasil diaktifkan.')));
    }
  }

Future<void> configureClosingReminder() async {
  final messageController = TextEditingController(
    text: await PosDb.instance.setting('closing_message') ??
        'JANGAN LUPA SEGERA PROSES BARANG YANG DIKERANJANG',
  );

  final timeController = TextEditingController(
    text: await PosDb.instance.setting('closing_time') ?? '22:00',
  );

  bool soundEnabled =
      (await PosDb.instance.setting('closing_sound') ?? 'true') == 'true';

  if (!mounted) return;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Pengingat tutup toko'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: messageController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Pesan pengingat',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: timeController,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(
                  labelText: 'Jam pengingat (HH:mm)',
                  hintText: '22:00',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Aktifkan suara'),
                value: soundEnabled,
                onChanged: (value) {
                  setDialogState(() => soundEnabled = value);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Tes sekarang'),
            onPressed: () async {
              try {
                final android = notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
                await android?.requestNotificationsPermission();
                await notifications.show(
                  2201,
                  'TES NOTIFIKASI RABAY CELL',
                  messageController.text.trim().isEmpty
                      ? 'Jika pesan ini muncul, notifikasi sudah diizinkan.'
                      : messageController.text.trim(),
                  NotificationDetails(
                    android: AndroidNotificationDetails(
                      'rabay_closing_alarm_v2',
                      'Pengingat Tutup Toko',
                      channelDescription: 'Pengingat alarm dan tes notifikasi Rabay Cell',
                      importance: Importance.max,
                      priority: Priority.high,
                      playSound: soundEnabled,
                      enableVibration: true,
                      vibrationPattern: Int64List.fromList(<int>[0, 900, 400, 900, 400, 1200]),
                      category: AndroidNotificationCategory.alarm,
                      audioAttributesUsage: AudioAttributesUsage.alarm,
                      fullScreenIntent: true,
                    ),
                  ),
                );
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Tes notifikasi gagal: $e')),
                  );
                }
              }
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Simpan'),
          ),
        ],
      ),
    ),
  );

  if (result != true) return;

  final parts = timeController.text.trim().split(':');
  if (parts.length != 2) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Format jam harus HH:mm, misalnya 22:00.')),
      );
    }
    return;
  }

  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);

  if (hour == null ||
      minute == null ||
      hour < 0 ||
      hour > 23 ||
      minute < 0 ||
      minute > 59 ||
      messageController.text.trim().isEmpty) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Jam atau pesan pengingat tidak valid.')),
      );
    }
    return;
  }

  final message = messageController.text.trim();

  await PosDb.instance.setSetting('closing_message', message);
  final normalizedTime = '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  await PosDb.instance.setSetting('closing_time', normalizedTime);
  await PosDb.instance.setSetting(
    'closing_sound',
    soundEnabled ? 'true' : 'false',
  );

  // Request exact-alarm access only when Android says it is not enabled.
  // If already enabled, saving a changed time will not reopen system settings.
  try {
    var canScheduleExact = await _nativeAlarmChannel.invokeMethod<bool>(
          'canScheduleExactAlarms',
        ) ?? false;
    if (!canScheduleExact) {
      final android = notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestExactAlarmsPermission();
      canScheduleExact = await _nativeAlarmChannel.invokeMethod<bool>(
            'canScheduleExactAlarms',
          ) ?? false;
    }
    if (!canScheduleExact) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Izin alarm belum aktif. Aktifkan Alarm dan pengingat untuk Rabay Cell, kembali ke aplikasi, lalu tekan Simpan lagi.')),
        );
      }
      return;
    }
  } catch (_) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tidak dapat memeriksa izin alarm. Periksa pengaturan Alarm dan pengingat di HP.')),
      );
    }
    return;
  }

  try {
    await scheduleClosingReminder(
      hour: hour,
      minute: minute,
      message: message,
      soundEnabled: soundEnabled,
    );
    await PosDb.instance.setSetting('closing_reminder_enabled', 'true');
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pengingat belum aktif. Periksa izin Alarm dan pengingat di Pengaturan HP, lalu coba Simpan lagi.')),
      );
    }
    return;
  }

  if (mounted) {
    setState(() => reminderEnabled = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Pengingat disimpan untuk pukul $normalizedTime.')),
    );
  }
}

  Future<void> changePin() async {
    final hasPin = await PosDb.instance.setting('pin_hash') != null;
    if (hasPin) {
      final old = await _askPin('Masukkan PIN lama');
      if (old == null) return;
      if (!await PosDb.instance.verifyPin(old)) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN lama salah.')));
        return;
      }
    }
    final next = await _askPin('Masukkan PIN baru (4–8 digit)');
    if (next == null || next.length < 4 || next.length > 8) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN harus 4–8 digit.')));
      return;
    }
    await PosDb.instance.setPin(next);
    await PosDb.instance.setSetting('owner_pin_enabled', 'true');
    if (mounted) {
      setState(() => pinEnabled = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN berhasil diubah.')));
    }
  }
  Future<String?> _askPin(String title) async {
    final c = TextEditingController();
    return showDialog<String>(context: context, builder: (ctx) => AlertDialog(title: Text(title),
      content: TextField(controller: c, keyboardType: TextInputType.number, obscureText: true, maxLength: 8,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'PIN')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Simpan'))]));
  }
  Future<bool> _requireOwner() async {
    final ok = await widget.requestUnlock();
    if (!ok) return false;
    return true;
  }

  Future<void> backupNow() async {
    if (!await _requireOwner()) return;
    try {
      final file = await PosDb.instance.createPortableBackup();
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/x-sqlite3', name: p.basename(file.path))],
        subject: 'Backup Rabay Cell',
        text: 'Backup database Rabay Cell. Simpan file ini di Google Drive untuk cadangan.',
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pilih Google Drive pada menu berbagi untuk menyimpan backup.')),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup gagal: $e')));
    }
  }

  Future<void> restoreNow() async {
    if (!await _requireOwner()) return;
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Restore backup?'),
      content: const Text('Data lokal saat ini akan diganti dengan isi file backup. Sebelum melanjutkan, pastikan kamu sudah membuat backup terbaru dari data sekarang.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pilih file backup'))],
    ));
    if (confirm != true) return;
    try {
      
final result = await FilePicker.platform.pickFiles(
  type: FileType.any,
  allowMultiple: false,
  withData: false,
);

      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) throw Exception('File tidak dapat diakses dari pemilih berkas ini. Coba unduh backup dari Google Drive ke perangkat terlebih dahulu.');
      await PosDb.instance.restorePortableBackup(path);
      if (mounted) {
        widget.onLock();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Restore berhasil. Data Rabay Cell sudah dipulihkan.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restore gagal: $e')));
    }
  }
  @override Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
      
Card(child: Column(children: [
      ListTile(
        leading: const CircleAvatar(child: Icon(Icons.notifications_active_outlined)),
        title: const Text('Pengingat tutup toko'),
        subtitle: const Text('Atur pesan, jam pengingat, dan suara notifikasi'),
        trailing: const Icon(Icons.chevron_right),
        onTap: configureClosingReminder,
      ),
      SwitchListTile(
        title: const Text('Aktifkan alarm harian'),
        subtitle: Text(reminderEnabled ? 'Alarm harian aktif' : 'Alarm harian dimatikan'),
        value: reminderEnabled,
        onChanged: _toggleReminder,
      ),
    ])),

    Card(child: Column(children: [
      ListTile(leading: const CircleAvatar(child: Icon(Icons.lock_outline)), title: const Text('PIN pemilik'),
        subtitle: const Text('Atur atau ganti PIN untuk membuka informasi rahasia'), trailing: const Icon(Icons.chevron_right), onTap: changePin),
      SwitchListTile(
        title: const Text('Aktifkan PIN pemilik'),
        subtitle: Text(pinEnabled ? 'Informasi rahasia dilindungi PIN' : 'PIN mati; informasi rahasia tidak dikunci'),
        value: pinEnabled,
        onChanged: _toggleOwnerPin,
      ),
    ])),
    Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.cloud_upload_outlined)), title: const Text('Backup ke Google Drive'),
      subtitle: const Text('Cadangkan database secara manual melalui menu berbagi Android'), trailing: const Icon(Icons.chevron_right), onTap: backupNow)),
    Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.cloud_download_outlined)), title: const Text('Restore dari backup'),
      subtitle: const Text('Pilih file .db dari Google Drive atau penyimpanan perangkat'), trailing: const Icon(Icons.chevron_right), onTap: restoreNow)),
    Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.backup_outlined)), title: const Text('Backup lokal otomatis'),
      subtitle: const Text('Salinan lokal tetap dibuat setelah transaksi dan perubahan'), trailing: const Icon(Icons.chevron_right), onTap: () async {
        if (!await _requireOwner()) return;
        await PosDb.instance.backup();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backup lokal berhasil dibuat.')));
      })),
    Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.visibility_off_outlined)), title: const Text('Sembunyikan informasi rahasia'),
      subtitle: const Text('Kunci tampilan modal dan keuntungan'), trailing: const Icon(Icons.chevron_right), onTap: widget.onLock)),
    const SizedBox(height: 16),
    const Text('Catatan: Backup ke Google Drive dilakukan manual. Pada menu berbagi, pilih Google Drive jika tersedia. Untuk restore, pilih file backup .db dari Google Drive atau unduh dahulu ke perangkat. Restore mengganti database lokal; file lama disalin sebagai cadangan sebelum pemulihan.'),
    const SizedBox(height: 8),
    const Text('Versi awal: SQLite lokal • Tidak memerlukan internet • Scanner yang berfungsi sebagai keyboard didukung melalui kolom scan.'),
  ]);
}
