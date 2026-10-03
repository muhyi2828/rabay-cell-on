# Rabay Cell — POS Android Offline

Starter project aplikasi kasir Android berbasis Flutter + SQLite lokal.

## Fitur yang tersedia dalam kode
- Tampilan utama bertema tosca dengan logo Rabay Cell.
- Tidak meminta PIN saat pertama membuka aplikasi.
- Saat fitur pemilik pertama kali digunakan, pengguna dapat membuat PIN 4–8 digit dan mengonfirmasinya.
- Informasi modal dan keuntungan disembunyikan secara default; PIN diperlukan untuk akses pemilik.
- Akses pemilik dikunci kembali ketika aplikasi menjadi inactive/paused (misalnya berpindah aplikasi atau layar dikunci).
- Data barang: nama, kode, barcode, harga modal, harga jual, stok, dan waktu terakhir diubah.
- Total modal seluruh stok = harga modal × stok setiap barang, lalu dijumlahkan; tersembunyi sampai PIN dibuka.
- Kasir mendukung barcode scanner USB/Bluetooth yang berperilaku seperti keyboard dan mengirim Enter.
- Keranjang dan nominal pembayaran disimpan ke SQLite agar bisa dipulihkan setelah aplikasi ditutup atau HP restart.
- Riwayat transaksi, edit transaksi, audit perubahan, pembatalan transaksi dengan pengembalian stok.
- Tutup sesi untuk menjumlahkan omzet/keuntungan dan mengarsipkan sesi; sesi berikutnya dibuat otomatis.
- Riwayat sesi hanya tersedia setelah akses pemilik dibuka.
- Backup database lokal setelah perubahan transaksi.
- Backup manual database ke file melalui menu berbagi Android (pilih Google Drive bila tersedia).
- Restore manual dari file backup `.db`, dengan validasi struktur/integritas dan salinan database lama sebelum diganti.
- Backup/restore memerlukan akses PIN pemilik.

## Membuat APK dari GitHub Codespaces / Linux
Pastikan Flutter SDK dan Android SDK tersedia di lingkungan build.

```bash
flutter pub get
flutter analyze
flutter build apk --release
```

APK hasil build berada di `build/app/outputs/flutter-apk/app-release.apk`.

## Catatan penting
- Ini adalah kode sumber awal; build dan pengujian di perangkat Android masih harus dilakukan.
- Data disimpan di penyimpanan privat aplikasi. Hapus data aplikasi atau uninstall dapat menghapus database dan backup lokal.
- PIN mengunci alur UI aplikasi, tetapi database SQLite belum dienkripsi. Untuk penggunaan komersial, uji dan audit keamanan lebih lanjut disarankan.
- Backup lokal otomatis tersimpan di direktori internal aplikasi, bukan folder Downloads. Untuk backup cloud, gunakan Pengaturan → Backup ke Google Drive, lalu pilih Google Drive pada menu berbagi Android. Jika Google Drive tidak muncul, simpan/unggah file melalui aplikasi Drive secara manual. Untuk restore, pilih file `.db`; file cloud tertentu mungkin perlu diunduh ke perangkat dahulu. File backup berisi data sensitif dan saat ini belum dienkripsi, jadi simpan hanya di akun Drive pribadi yang aman.

## Membuat APK melalui GitHub Actions
Workflow tersedia di `.github/workflows/build-apk.yml`.
1. Unggah isi folder proyek ini ke repository GitHub.
2. Buka tab **Actions** dan pilih **Build Rabay Cell APK**.
3. Tekan **Run workflow** (atau push ke branch `main`/`master`).
4. Setelah job selesai, buka hasil run dan unduh artifact `rabay-cell-apk`.

Workflow membuat kerangka Android Flutter sementara di server, lalu memasukkan kode aplikasi ini dan membangun APK. Dengan cara ini folder platform Android tidak perlu dibuat manual di HP.
