# ARNotch — catatan pengembangan

## Stack

- Swift Package (`Package.swift`, swift-tools-version 5.10, **Swift 5 language mode**, macOS 14+), satu executable target `ARNotch` di `Sources/ARNotch`. Tanpa dependency pihak ketiga dan tanpa proyek Xcode.
- Aplikasi `LSUIElement` (tanpa ikon Dock), non-sandboxed. Bundle id `id.crest.app` sengaja dipertahankan dari versi awal supaya izin macOS dan pengaturan pengguna lama tetap berlaku.

## Hal yang perlu diketahui

- **Toolchain:** pakai `/usr/bin/swift` / `/usr/bin/swiftc`. Toolchain *swiftly* yang lebih lama bisa tidak cocok dengan SDK macOS terbaru.
- **`@State`:** dengan Command Line Tools, macro `@State` tidak punya plugin compiler. Kode memakai properti tersimpan `State(initialValue:)` (`x.wrappedValue`, `x.projectedValue`). `@StateObject`, `@ObservedObject`, `@Published`, `@EnvironmentObject`, `@AppStorage` berfungsi normal.
- **Animasi:** animasi yang berjalan terus (visualizer, titik berkedip, lonceng) wajib memakai helper Core Animation di `Core/LayerAnimations.swift`. `TimelineView(.animation)` atau `repeatForever` di SwiftUI membuat seluruh hosting view di-render ulang setiap frame (12–20% CPU).
- **TCC saat tes:** menjalankan binary langsung dari shell membuat shell menjadi "responsible process", sehingga akses Bluetooth akan meng-abort aplikasi. Tes selalu lewat `open -n dist/ARNotch.app --args …`.
- **Flag debug:** `--debug-open home|shelf|timer|system|connectivity` (membuka dan menahan notch), `--debug-timer <detik>` (timer ini tersimpan; hapus dengan `defaults delete id.crest.app timer.items`).

## Struktur

```
Sources/ARNotch/
  Core/
    ARNotchApp.swift          @main, AppDelegate (menu bar, jendela Settings, start service modul, flag debug)
    AppSettings.swift         preferensi di UserDefaults
    NotchViewModel.swift      tab, ClosedActivity (wing saat notch tertutup), ukuran, hold (menahan notch tetap terbuka)
    NotchWindowController.swift  NSPanel di atas menu bar, hover buka/tutup, NotchDropCatcher untuk drag file
    NotchRootView.swift       bentuk notch, wing, header tab, isi tab
    NotchShape.swift          siluet notch
    LayerAnimations.swift     helper Core Animation
  Modules/
    Media/         Now Playing: bridge sistem (Helpers/NowPlayingBridge.m dijalankan lewat /usr/bin/perl
                   karena macOS 15.4+ membatasi MediaRemote), fallback AppleScript untuk Spotify/Music
    Shelf/         file sementara (~/Library/Application Support/Crest), drag masuk/keluar, AirDrop
    Battery/       IOKit power source, kesehatan baterai (AppleSmartBattery)
    Calendar/      EventKit
    Mirror/        AVCaptureSession, foto (~/Pictures/ARNotch) dan video (~/Movies/ARNotch)
    Timer/         timer, alarm, Pomodoro (tanggal absolut, tersimpan, ticker hanya saat aktif)
    System/        CPU/RAM/jaringan, proses per aplikasi, Quit/Force Quit, deteksi hang (Accessibility)
    Ports/         server localhost via libproc (tanpa lsof), Open/Copy/Stop→Kill
    Connectivity/  Core Audio, display (Extend/Mirror via Quartz, Blank via panel hitam), aksesori + baterai BLE
    Settings/      jendela Settings, launch at login (SMAppService), status izin
Helpers/NowPlayingBridge.m    dylib yang dimuat oleh perl untuk membaca Now Playing sistem
tools/make_icon.swift         generator ikon (ikon saat ini: Resources/AppIcon.icns)
```

## Prinsip

- Kelas UI memakai `@MainActor`, dan pekerjaan berat (IOKit, AppleScript, libproc, kamera) berjalan di background queue.
- Tidak ada timer atau sampling saat tidak ada yang terlihat. CPU saat notch tertutup sekitar 0,1%.
- Izin hanya diminta setelah pengguna mengklik fiturnya.
- Proses milik sistem, root, atau ARNotch sendiri tidak pernah bisa di-Quit atau di-Kill dari aplikasi.

## Keterbatasan yang diketahui

- Alarm tidak berbunyi saat lid MacBook tertutup (ditandai sebagai missed saat Mac bangun).
- Trik `perl` untuk Now Playing bisa ditutup Apple di update macOS berikutnya. Jika itu terjadi, ARNotch otomatis kembali ke Spotify/Music.
- Belum dinotarisasi, jadi pengguna lain perlu "Open Anyway".
- Port yang dibuka oleh root (misalnya Valet/MAMP port 80 dengan hak admin) tampil terkunci.
