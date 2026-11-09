# PearSilicon — Çalışma Durumu

## Tamamlandı — dal birleştirme, motor/JIT entegrasyonu ve sürüm (2026-11-09)

- `codex/pear-legacy-engine` ile `denizomer10-pear-legacy-engine` karşılaştırılıp
  tüm yeni değişiklikler birleştirildi ve `main`'e alındı. Sanal gamepad dalı ile
  32 bit PearLegacyEngine dalı artık tek hatta.
- Çakışmalar uygulanan (yayınlanmış) `denizomer10` hattı lehine çözüldü: gerçek
  motor başlatma yolu `AppLauncher.launchLegacy32Bit` (PID kaydı, `Hosts/<id>.app`
  paketleme, `PEAR_LEGACY_RESOURCES_DIR`) korundu. codex hattının ikinci,
  kullanılmayan `LegacyIOSRuntime`/`LegacyAppLauncher` kopyası testleriyle birlikte
  kaldırıldı. codex'in belge ve rozet katkıları (`docs/ARCHITECTURE.md`,
  `docs/CLI.md`, `InstalledApp.isLegacy32Bit`, uygulama satırı rozeti) tutuldu.
- Lisanslar: `THIRD_PARTY_NOTICES.md` eklendi — PearLegacyEngine MPL-2.0
  (touchHLE türevi, ayrı süreç olarak çalıştırılır), PearLegacyJIT 0BSD
  (Dynarmic türevi, motorun içine derlenir), ANGLE BSD-3-Clause. Sabitlenen
  commit'ler `docs/ARCHITECTURE.md` içinde tablo hâlinde.
- `scripts/setup-legacy-engine.sh` eklendi: iki depoyu bulur, motoru JIT fork'una
  karşı derler ve `build/PearLegacyEngine/` altına yayın düzenini kurar
  (`touchHLE`, `touchHLE_dylibs/angle` dahil, `touchHLE_fonts`,
  `touchHLE_default_options.txt`). `build-app.sh` bu klasörü pakete kopyalıyor.
- Sürüm: PearSilicon **v0.7.0** (yapı 24), PearLegacyEngine **v0.7.2**
  (`84e3f1bd`, PearLegacyJIT `1fc35bfd` ile derlendi).

## Tamamlandı — PearLegacyEngine entegrasyonu (2026-11-09)

32 bit iOS uygulamaları artık yalnızca IPA seçilerek kurulup PearLegacyEngine
üzerinde çalıştırılabiliyor. Uçtan uca doğrulandı: `pearsilicon install
MikuFlick02.ipa` → `pearsilicon launch com.sega.MikuFlick02` → oyun çizim
döngüsünde çalışıyor → `pearsilicon stop` temiz kapanış.

- Motor sürümü: **PearLegacyEngine v0.7.2** (ANGLE/Metal, macOS 26, arm64).
  Sürüm: https://github.com/denizomer10/PearLegacyEngine/releases/tag/v0.7.2
- Kurulum yolu: motor `touchHLE <app>` olarak ayrı bir süreçte çalışır. Motor
  klasörü `PEAR_LEGACY_ENGINE_HOME` ile veya şu sırayla bulunur:
  `<destek kökü>/PearLegacyEngine`, uygulama paketi kaynakları, çalışma dizini
  ve ev dizini.
- ANGLE dizini için hem yayın düzeni (`touchHLE_dylibs/angle`) hem kaynak
  düzeni (`vendor/angle/out/MacMetal`) kabul edilir.
- 32 bit paketler (armv6/armv7, arm64 yok) macOS/Catalyst kabul kontrollerini ve
  hazırlık adımlarını atlar: paket birebir korunur; `prepareForMacOS`, runtime
  enjeksiyonu, `codesign` ve platform yaması uygulanmaz. Yalnızca çalıştırma izni
  geri verilir.
- Her uygulama kendi emüle cihaz ağacını `Games/<bundleID>` altında tutar
  (`PEAR_LEGACY_SANDBOX_ROOT`); kayıtlar uygulama başına kalır.
- Çalışan motor süreçleri `Runtime/LegacyProcesses/<bundleID>.pid` dosyalarıyla
  izlenir; böylece GUI ve CLI birbirinin başlattığı süreci görüp durdurabilir.
  Başlatma/durdurma, Metal HUD ve keymapper kaplaması (`PEAR_KEYMAP`) mevcut
  arayüzde değişmeden çalışır.
- Arayüzde 32 bit uygulamalar satırda `32-bit` rozeti ve ayrıntı görünümünde
  `Runtime: PearLegacyEngine (32-bit iOS)` bilgisiyle işaretlenir.
- Testler: mimari tespiti, mach-o başlıkları, motor keşfi
  (`PEAR_LEGACY_ENGINE_HOME`), 32 bit IPA kurulumunun hazırlıksız geçmesi ve 64
  bit paketlerin hazırlık yolunu kullanmaya devam etmesi kapsanıyor. Tüm paket:
  314 XCTest (16 atlandı) + 24 Swift Testing, 0 hata.
- Bilinen sınır: Asphalt 6 (`com.gameloft.Asphalt6ipad`, fat armv6+armv7)
  kurulup başlatılıyor, iki GL bağlamı da açılıyor (ES 1.1 + ES 2.0) ve oyun ana
  başlatmaya (`GLAppleMain::SetInitState`) kadar geliyor; ardından misafir kod
  `PC=0x70ee0` adresinde düşüyor. Kesme noktası:
  `ldr r1,[sp,#0x28] / ldr r1,[r1] / ldr r1,[r1,#8]` — yani bir arama/çözümleme
  null dönüyor ve sonucu `+8` ofsetinden okuyor. Motor/grafik hatası değil;
  kaynak dosyalar `.dat` bloklarında olduğu için `Anim_ProjectorBeam.tga`,
  `*.wav` gibi "bulunamadı" uyarıları normaldir, `--allow-network-access` da
  sonucu değiştirmiyor. Miku Flick ve Miku Flick 02 çalışıyor. GTA VC (arm64)
  eski Catalyst yolunu kullanmaya devam ediyor.
- Motor tanılama: `open()` hataları artık misafir yolunu da yazıyor
  (PearLegacyEngine `5b4654a0`); eksik kaynak ayıklaması bellek dökümü
  gerektirmiyor.

## Aktif hedef — PearLegacyEngine (32-bit iOS) ve Miku Flick (2026-11-08)

- PearSilicon çalışma dalı: `denizomer10-pear-legacy-engine`.
- **Ana hedef:** Miku Flick'i (`com.sega.MikuFlick`) baştan sona oynanabilir hale
  getirmek; ardından PearLegacyEngine'i PearSilicon'a entegre edip iOS
  sekmesinden **yalnız IPA seçilerek** kurulup açılabilmesini sağlamak.
- **Geliştirilecek bileşen:** `PearLegacyEngine` (32-bit iOS uyumluluk katmanı).
  Fork: `denizomer10/PearLegacyEngine`; yerel çalışma kopyası
  `/Users/mac/PearLegacyEngine`.
- **Referanslar:** `HyperHLE-Reborn` (`/Users/mac/HyperHLE-Reborn`; olgun ES 2
  yolu) ve PearLegacyEngine'in kendi `codex/hyperhle-es2-reference` dalı
  (`7bd91764 Implement OpenGL ES 2.0 support`).
- **PearSilicon tarafı:** mevcut iOS kurulum akışı
  (`IOSAppService`, `PackageInstaller`, `AppLauncher`, `PlatformShim`) 32-bit
  armv7 IPA'ları çalıştıramıyor; PearLegacyEngine yürütücüsü buraya bağlanacak.

### Sanal gamepad dalı birleşimi (2026-11-08)

`origin/denizomer10-virtual-gamepad-inputs` (`0.4.9`) dalı bu dala birleştirildi;
artık tek dalda hem sanal gamepad girdi yolu hem 32-bit motor katmanı var.

- **Sanal gamepad:** gizli `GCVirtualController` shim'i (`runtime/VirtualGamepadShim.mm`)
  klavye/fare olaylarını `PEAR_VIRTUAL_GAMEPAD_MAP` eşlemesiyle denetleyici
  öğelerine çevirir; `Keymap` sekmesindeki "Keyboard Mouse to Gamepad Inputs"
  anahtarıyla açılır.
- **Otomatik uyumluluk:** sahne bildirimi olmayan ve `DTSDKName` ana sürümü 15'in
  altında derlenmiş oyunlarda pencere yeniden bağlama ve fare→dokunma köprüleri
  `Info.plist`'ten tespit edilip kendiliğinden uygulanıyor.
- **32-bit tarafta:** `PearLegacyEngine` arm64 çalışma zamanı dylib'i emüle edilen
  uygulamaya enjekte edilemediği için sanal gamepad 32-bit başlıklarda devre dışı;
  `Keymap` sekmesi bu durumda bilgi notu gösteriyor ve tuş eşlemeleri motorun
  `PEAR_KEYMAP` yoluyla gerçek dokunmaya çevriliyor.
- **Sürüm düzeltmesi:** yanlış numaralandırılan `v0.4.0` motor sürümü kaldırıldı;
  yerine **PearLegacyEngine v0.5.0** yayınlandı ve PearSilicon **0.5.0 (22)**
  olarak derlendi.
- **Doğrulama:** `swift build -c release`, `swift test` 24/24,
  `./scripts/build-app.sh release` başarılı; paket içindeki çalıştırıcı
  `PearLegacyEngine v0.5.0` yazıyor.

### Durum (bu oturum — tamamlandı, 2026-11-08)

1. **PearLegacyEngine (`denizomer10/PearLegacyEngine`, commit `187462cc`):**
   - `codex/es2-port` ve `codex/miku-flick` dalları güncellendi ve fork'a push edildi.
   - OpenGL ES 2.0 uyumluluk bağlamı (OpenGL 2.1 + GLSL 120), shader/program/framebuffer/renderbuffer API'leri tamamlandı (`glGenFramebuffers` sıfır olmayan ID garantisi dahil).
   - Miku Flick (`com.sega.MikuFlick`) başlangıç ve oyun içi çökmeleri giderildi:
     - `___stack_chk_guard` ve `___stack_chk_fail` sembolleri eklendi.
     - `NSString` geçersiz UTF-8 (`stringWithUTF8String:` / `initWithBytes:length:encoding:`) güvenli fallback ile düzeltildi.
     - `AudioUnitGetProperty` / `AudioUnitSetProperty` global ve output scope özellikleri eklendi.
     - `CFAbsoluteTimeGetCurrent`, `NSFileManager` (`createDirectoryAtPath:...`), `NSHTTPCookieStorage` ve `NSKeyedArchiver` / `NSKeyedUnarchiver` (`initForReadingWithData:`, `initForWritingWithMutableData:`, `decodeObjectForKey:`, `encodeObject:forKey:`, `finishEncoding`) gerçek arşivleme desteğiyle tamamlandı.
   - Dokunma enjeksiyonu (`PEAR_TOUCH_SCRIPT`) ve kare yakalama (`PEAR_DUMP_FRAME`) ile oyun içi akış (SEGA logosu → başlık ekranı → ana menü → şarkı seçimi → 3D PV ve ritim notalarıyla aktif oynanış) baştan sona doğrulandı.
2. **PearSilicon 32-bit iOS Entegrasyonu:**
   - `BinaryPatcher`: 32-bit ARM Mach-O (`magic32 = 0xFEEDFACE`, `cpuTypeARM = 12`, `LC_SEGMENT`, şifresiz `LC_ENCRYPTION_INFO`) tespiti ve doğrulaması (`isLegacy32BitARM`, `fileIsLegacy32BitARM`, `validateLegacy32BitARM`) eklendi.
   - `PackageInstaller`: 32-bit iOS uygulama paketlerinin (`isLegacy32BitBundle`) 64-bit Mac Catalyst yamalarına sokulmadan doğrulanıp `ios-apps/<bundleID>.app` altına kurulması ve EFS bayrağı eksik UTF-8 dosya adlarında (`mf01_icon_152ｘ152_Flatdesign.png`) `unzip -t` doğrulaması sonrası `ditto -x -k` fallback'i eklendi.
   - `AppLauncher`, `IOSAppService`, `AppState`, `CLI`: 32-bit iOS uygulamalarının otomatik olarak `PearLegacyEngine` (`touchHLE`) üzerinden başlatılması, çalışma dizini (`touchHLE_dylibs`, `touchHLE_fonts`, `touchHLE_default_options.txt`) yönetimi ve PID takibi (`legacyRunningPID`, `runningApplication`, `stop`) eklendi.
   - `scripts/build-app.sh`: `PearLegacyEngine` ikilisini ve kaynaklarını `PearSilicon.app/Contents/Resources/PearLegacyEngine/` içine otomatik paketleme adımı eklendi ve release paketi üretildi.
   - Birim testleri (`BinaryPatcherTests`, `InstallerIntegrityTests`) eklendi; tüm `swift test` paketi ve `PearSilicon.app` üzerinden Miku Flick IPA kurulum + başlatma + durdurma akışı uçtan uca doğrulandı.
3. **Apple Silicon Derin Optimizasyon, Headless Motor ve SwiftUI Yeniden Tasarımı:**
   - **PearLegacyEngine Headless & Marka Temizliği:** Eski SDL `app_picker` arayüzü devre dışı bırakılarak motor tamamen PearSilicon tarafından yönetilen headless/CLI çalışma zamanına dönüştürüldü. Pencere başlığı, SDL `SDL_APP_NAME` ipucu ve hata diyaloglarından `touchHLE` / motor adı kaldırılarak yalnızca oyunun kendi adının (`bundle.display_name()`) görünmesi sağlandı.
   - **Apple Silicon Performans Optimizasyonları:** `Cargo.toml` içine `[profile.release]` (`opt-level = 3`, `lto = "thin"`, `codegen-units = 1`, `strip = "debuginfo"`) ve `.cargo/config.toml` içine `-C target-cpu=apple-m1` eklendi. `eagl.rs` içindeki `presentRenderbuffer` sıcak döngüsünde her karede yapılan `std::env::var("PEAR_DUMP_FRAME")` sistem çağrısı `LazyLock` ile önbelleğe alındı; `log.rs` içindeki `touchHLE::dyld` debug log spam'i ve çalışma dizininde gereksiz `touchHLE_log.txt` oluşturma davranışı kapatıldı.
   - **SwiftUI 32-bit Kontrolleri ve macOS Host Sarmalayıcısı (`AppLauncher` & `AppDetailView`):** 32-bit oyunlar başlatılırken `Legacy32/Hosts/<bundleID>.app` altında oyunun kendi adı (`CFBundleName` / `CFBundleDisplayName` / çalıştırıcı adı) ve ikonuyla hafif bir macOS uygulama paketi oluşturularak macOS 26 menü çubuğu ve pencere başlığında yalnızca oyun adının görünmesi sağlandı. `AppDetailView` içine 32-bit mimari rozeti, çözünürlük ölçeği (`1x`–`4x`), tam ekran başlatma, FPS loglama ve Kayıt Verileri (`Save Data`) klasörünü açma kontrolleri eklendi.
   - **Dokümantasyon:** `PearLegacyEngine/README.md` baştan aşağı PearSilicon'a bağımlı Apple Silicon 32-bit iOS motoru olarak yeniden yazıldı; `PearSilicon/README.md` güncellendi.

4. **32-bit Keymapper ve Performans HUD'u (Miku Flick tam oynanabilirlik):**
   - **Motor içi keymapper (`PearLegacyEngine/src/keymap.rs`, yeni):** 32-bit oyunlarda `PEAR_KEYMAP` daha önce yalnızca arm64 `PearRuntime.mm` dylib'i tarafından okunuyordu ve emüle edilen ARM32 sürece enjekte edilemiyordu. Bu yüzden keymapper motorun içine taşındı: bağımlılıksız (serde yok) bir `pear-keymap/v1` JSON ayrıştırıcısı, `tap` / `hold` / `swipe` / ölü bölgeli `joystick` eylemleri ve `FingerId::Keymap` parmak kimliği eklendi. Tuş basımları gerçek dokunma olaylarına dönüştürülüp UIKit'e teslim ediliyor; `space` (tap) ve `d` (joystick sağ) ile uçtan uca doğrulandı (`Finger Keymap(…) touch down/move/up` logları).
   - **Performans HUD'u (`src/gles/present.rs`):** Metal HUD 32-bit oyunlarda çalışmıyor (motor OpenGL ES ile çiziyor). `PEAR_FPS_HUD=1` ile yedi parçalı segmentlerden oluşan, tahsis yapmayan bir FPS katmanı oyun görüntüsünün üzerine çiziliyor; renk eşikleri (≥50 yeşil, ≥28 amber, altı kırmızı) ve `LAST_FPS` atomiği ile hem `composition.rs` hem `eagl.rs` sayaçları besliyor.
   - **PearSilicon bağlantısı:** `launchLegacy32Bit` artık `keymapURL` alıp `PEAR_KEYMAP` ayarlıyor; 32-bit ayarlarındaki "Log FPS" anahtarı **"Performance HUD (FPS)"** olarak yenilendi ve `PEAR_FPS_HUD=1` ile birlikte `--print-fps` geçiyor. `PEAR_DEBUG_MODULES` ile istenen modüller için ayrıntılı motor logları açılabiliyor.
   - **Doğrulama:** `cargo test --release` 42/42, `swift test` 24/24, `./scripts/build-app.sh release` başarılı; HUD self-test okuması 320×480 görüntüde 687 katman pikseli sayarak katmanın gerçekten çizildiğini kanıtladı.

---

Son güncelleme: 2026-11-08 · Dal: `denizomer10-pear-legacy-engine` (sanal gamepad dalı birleştirildi)
Son commit: sanal gamepad dalı (`0.4.9`) + 32-bit motor katmanı birleşimi
Uygulama paketi: **0.5.0 (22)**; gömülü çalıştırıcı **PearLegacyEngine v0.5.0**
Web sitesi: `pearsilicon-web` (release listesi indirme bağlantısı ve gerçek sürüm notları)

Bir sonraki geliştirici/agent §0, §1 ve §4'ü okuyarak kaldığı yerden devam edebilir.

---

## 0. 0.4.9 (2026-11-07) — Logo, giriş, LCS ve FPS

- **Logo:** SwiftUI'ın paketlenmiş/translocate edilmiş uygulamada çözemediği
  `Image("PearLogo", bundle: .module)` yolu bırakıldı. Logo artık
  `Bundle.module` URL'i üzerinden `NSImage` ile yükleniyor; üst çubuk, boş
  durum ve Hakkında ekranlarında aynı `PearBrand.logo` kullanılıyor. PNG'nin
  gerçekten görünür piksel ürettiği offscreen `ImageRenderer` testiyle
  doğrulanıyor.
- **Minecraft PE / modern dokunma:** fare→dokunma fallback'i artık modern
  profilli uygulamalarda da varsayılan açık. Native bir UIKit dokunuşu 220 ms
  içinde gelirse sentetik dokunuş iptal edilir; böylece normal fare kullanan
  uygulamalarda çift tıklama oluşmaz. Çalışan Minecraft süreci izinsiz
  kapatılmadı; oyun içi tıklama doğrulaması kullanıcıya bırakıldı.
- **GTA LCS:** El yazımı assembly/boş conformance descriptor yerine
  `PearUIKitNumeric.swift` derleyici tarafından `UIKit` modülü olarak üretiliyor.
  `_UIKitNumericRawRepresentable`, operatörler ve `UIWindow.Level` uyumu gerçek
  Swift ABI'siyle eşleşiyor; LCS açılışta çökmüyor ve 30 saniyeden uzun süre
  ayakta kalıyor.
- **Durdurma:** GUI ve yönetilen süreçlerde Stop artık doğrudan `SIGKILL`
  gönderiyor; 250 ms sonra durum uzlaştırılıyor. Askıda kalan oyun penceresi
  kapanmadan beklemiyor.
- **FPS HUD:** EAGL `presentRenderbuffer:` sayacı eklendi. HUD ayrı bir pencere
  yerine oyun penceresinin içine, dokunuşları geçiren bir alt view olarak
  yerleşiyor; böylece tıklamaları yutamıyor. `PEAR_FPS_HUD=1` yalnız gerçek bir
  OpenGL ES karesi sunulduktan sonra kuruluyor; modern algılanan ama OpenGL
  kullanan LCS de kapsanıyor, saf Metal uygulamalar `MTL_HUD_ENABLED` ile
  kalıyor. GTA III'te `[PearRuntime][hud] FPS overlay installed (OpenGL ES)`
  logu doğrulandı.
- Yeni logo render regresyon testi eklendi.

---

## 0.1 0.4.8 (2026-11-07) — GTA III ve LCS

- **GTA III** (`com.rockstargames.gta3ios` 1.3.13, SDK 12.1, legacy):
  beyaz ekran, otomatik legacy köprünün UIKit kök layer'ını AppKit host'a
  bağlamasıyla giderildi. Oyun açılıyor ve `EAGLView` çiziyor.
- **GTA III dokunma:** `PEAR_DIRECT_LEGACY_TOUCH` yolu artık `EAGLView`'a
  ulaşıyor; loglarda `touchesBegan`/`touchesEnded` görülüyor. Oyun gamepad ile
  sorunsuz; fare→dokunma eşlemesi çalışıyor ancak hassasiyeti/konumu tam değil.
  Dokunma koordinatı ve çoklu dokunma iyileştirmesi sonraki adım.
- **GTA LCS** (`com.rockstargames.gtalcs` 2.4.150, SDK 16.2): açılışta
  `RockstarMobile` timer'ında null fonksiyon çağrısıyla çöküyordu. Eksik
  `UIKit._UIKitNumericRawRepresentable.+` sembolü `libswiftUIKit.dylib` içine
  eklendi; kurulu uygulamanın dylib'i yamanıp yeniden imzalandı. Süreç artık
  açık kalıyor; yeni crash raporu üretilmiyor.
- Teşhisler `PEAR_DEBUG_GL`, `PEAR_DEBUG_TOUCH` ve `PEAR_DEBUG_VIEWS` ile
  isteğe bağlı; normal oyunda ek log üretilmez.

---

## 1. Kısa özet

- Üç platformlu kütüphane, Wine motorları, DXVK/DXMT grafik bileşenleri çalışıyor.
- **Grafik (2026-10-31):** DELTARUNE siyah ekranı DXVK 1.10.3 + MoltenVK ile
  çözüldü; uygulamaya motor düzeyinde pinli bileşen olarak entegre edildi
  (ayrıntı için git geçmişi `bf4c63f`).
- **Bu oturum (2026-11-01):**
  1. GameController/denetleyici desteği runtime'a eklendi: erken keşif, kimlik
     normalizasyonu (Switch Pro → Xbox), geç kaydedilen observer'a connect
     bildirimi tekrarı. Catalyst probe ile doğrulandı; Genshin'in runtime kopyası
     güncellendi (oyun çalışırken; sonraki açılışta etkin).
  2. Güncelleme kanalları düzeltildi: Stable yalnız normal (prerelease olmayan,
     numaralı) release'lerden; Development Beta prerelease/development
     release'lerden seçilir.
  3. "Community engine" artık GitHub linkiyle çalışıyor: en yeni release asset'i
     otomatik bulunur; release yoksa repo kaynak ZIP'i indirilip açılır. Kullanıcı
     hash girmez; GitHub digest'i varsa doğrulanır.
  4. Kayıtlı Wine motorları Settings'ten **kaldırılabilir** (yalnız motor dizini
     silinir; oyun prefix'leri/save'leri korunur).
  5. **KosmicKrisp kaldırıldı**; grafik seçenekleri MoltenVK(+DXVK) ve DXMT.
  6. GUI: PearSilicon logosu (pear) üst çubukta; platform seçici Liquid Glass ve
     sürüklenebilir; Hakkında ve Settings'te sürüm "Development Beta" görünür.
  7. Settings → Wine'daki **WineHQ Stable** seçeneği kaldırıldı (Staging/Development
     kalır).
  8. Güncelleme kontrolü 403 düzeltildi: GitHub API rate limitinde public release feed/HTML'e düşer; tag/commit/digest yine doğrulanır. Settings'te yalnız **Check for Updates** kaldı. Her build ayrı release (`v0.4.3`); About/Ayarlar gerçek sürümü gösterir.
  9. Disk temizliği: 31 GB `.build` test çöpü ve yeniden üretilebilir cache'ler
     silindi; sistem veri alanı 14 GB → 37 GB boş. Oyun verisi indirmesi/save'ler
     korundu.

---

## 2. Denetleyici (GameController) — kanıt ve çözüm

### 2.1 Bulgular

- Runtime yalnız `GCKeyboard`/`GCMouse` kullanıyordu; `GCController` için hiçbir
  köprü yoktu.
- Genshin (iOS build) `GameController.framework`'ü **weak link** ediyor;
  `MHYGameController`, `MHYJoypad`, `setupControllerInputHandler:` ve
  `[MiHoYoGamepad] Gamepad connected:` kodları var. Uygulama
  `GCController.controllers` sorguluyor ve 1 denetleyici görüyor, ancak
  `[MiHoYoGamepad]` logu hiç üretilmiyordu → uygulama resmi iOS whitelist'i
  (Xbox / Xbox Elite / DualShock 4) dışındaki "Pro Controller"ı yok sayıyor.
- macOS, Switch Pro'yu GameController üzerinden sunuyor; Catalyst probe (scene
  tabanlı) `controllers=0` ile başlayıp ~1 sn içinde "Pro Controller" connect
  bildirimi alıyor. Yani keşif **asenkron**; erken sorgulayan uygulamalar boş
  liste görüyor.

### 2.2 Runtime çözümü

`runtime/PearRuntime.mm` içinde `InstallGameControllerBridge()`:

- Bootstrap'ta `[GCController controllers]` çağrılarak keşif erkene alınır.
- Connect/disconnect gözlenir; denetleyiciler canlı tutulur ve loglanır.
- **Varsayılan açık kimlik normalizasyonu:** Xbox/Sony dışındaki denetleyiciler
  `vendorName = "Xbox Wireless Controller"`, `productCategory = "Xbox One"`
  olarak raporlanır. Profil/eksenler değişmez.
- **Varsayılan açık replay:** uygulama başladıktan 3 sn sonra mevcut denetleyiciler
  için `GCControllerDidConnectNotification` yeniden gönderilir; böylece geç
  observer kuran oyunlar da haberdar olur.
- `PEAR_CONTROLLER_NATIVE=1` ile ikisi de kapatılabilir; `PEAR_CONTROLLER_REPLAY=0`
  sadece replay'i kapatır. `AppLauncher` bu varsayılanları açıkça set eder.
- `PearRuntime` içindeki değişiklik `./runtime/build.sh` ile derlenir; her iOS app
  kendi kopyasını taşıdığı için yeniden kurulum veya **Refresh iOS Runtimes**
  (veya elle kopyalama) gerekir.
- **Info.plist:** `PackageInstaller.patchInfoPlist` artık uygulama kendi
  bildirmediyse `GCSupportsControllerUserInteraction = true` ve
  `GCSupportedGameControllers = [ExtendedGamepad, MicroGamepad]` ekler. Bu
  anahtarlar olmadan iOS-on-Mac sistemi uygulamayı denetleyici destekli saymıyor;
  kollar görünse de giriş yönlendirilmiyordu. Kurulu Genshin Info.plist'i
  güncellendi ve yeniden imzalandı (çalışan süreç etkilenmez).

### 2.3 Doğrulama

- Catalyst probe (`/tmp/CatProbe2.app`, `open --env DYLD_INSERT_LIBRARIES=…`):
  - `scene controllers=0` → `connected Xbox Wireless Controller`
  - t+1 ve t+4: `vendor=Xbox Wireless Controller`, `extended=true`
  - runtime: `controller 'Pro Controller' reported as Xbox Wireless Controller`,
    `replay tick: 1 controller(s)`.
- Genshin'in kurulu runtime'ı yeni sürümle değiştirildi (oyun çalışırken; çalışan
  süreç eski inode'u kullanır). **Oyun yeniden başlatılınca** yeni runtime yüklenir.
  Kullanıcı oyunu indiriyor/oynuyordu; izinsiz kapatılmadı.

---

## 3. Bu oturumdaki diğer değişiklikler

### 3.1 Güncelleme kanalları

- `AppUpdateService.checkForUpdates`: önce `/releases` listesi.
  - **Stable:** draft olmayan, `prerelease == false`, numaralı (`v1.2.3`) release'ler
    arasından en yüksek sürüm.
  - **Development Beta:** en yeni prerelease veya `development`/`beta` etiketli
    release (mutable `development-beta` dahil).
  - Liste alınamazsa eski tek-release endpoint'lerine düşer.
- `selectAsset` geliştirme kanalında artık yalnız `development-beta` etiketini
  şart koşmuyor.
- Testler: `AppUpdateTests` liste endpoint'ine göre güncellendi; stable'ın
  prerelease'i yok saydığını doğrulayan test eklendi.

### 3.2 Community engine (GitHub linki)

- `CommunityWineService`: `https://github.com/owner/repo` (veya `owner/repo`)
  kabul eder; `/releases` üzerinden en yeni uygun arşivi seçer
  (`.tar.xz/.tar.gz/.zip`; macOS adı tercih edilir).
- Release yoksa `codeload.github.com` üzerinden repo ZIP'i indirilir ve
  `ditto` ile açılır; ZIP yolları `unzip -Z1` ile denetlenir.
- Kullanıcıdan hash istenmez; GitHub'ın `digest` alanı varsa SHA-256 doğrulanır.
  İndirme yalnız GitHub host'larına yönlendirilir; 8 GiB sınırı vardır.
- Settings → Wine → "Community engine from GitHub": tek URL alanı + lisans onayı.
- `Engines/Downloads` altına kaydedilir; motor kaydı yine açık "Add Local Engine…"
  adımıdır (keyfi arşiv otomatik çalıştırılmaz).

### 3.3 Motor kaldırma

- `WineEngineStore.remove(id:)`: yalnız doğrulanmış motor dizinini siler;
  `validateID`, manifest ve kök-yol denetimleri vardır.
- Settings → Registered engines: çöp kutusu düğmesi + onay uyarısı. Çalışan oyun
  varsa AppState reddeder. Oyun prefix/save'leri silinmez.
- Test: `testRemovingAnEngineDeletesOnlyThatEngine`.

### 3.4 KosmicKrisp kaldırıldı

- `GraphicsBackend` artık `moltenvk` ve `dxmt`; eski manifestlerdeki
  `"kosmickrisp"` değeri `moltenVK`'ya düşer (kod okunabilirliği korunur).
- `GraphicsComponentService`'ten KosmicKrisp indirme/kurma kodu, UI ve testler
  kaldırıldı; README/ARCHITECTURE güncellendi.

### 3.5 GUI

- Üst çubukta SF Symbol yerine `PearLogo.png` (Resources; `Image(_:bundle:.module)`).
- Platform seçici zaten `glassEffect` kullanıyordu; `interactive()` + gölge +
  `DragGesture` ile sürüklenebilir hale getirildi (tıklama çalışmaya devam eder).
- Hakkında penceresi ve Settings → Updates "Current version" = **Development Beta**
  (iç `CFBundleShortVersionString` güncelleme karşılaştırmaları için sayısal kalır).
- WineHQ Stable seçeneği Settings'teki kanal seçicisinden kaldırıldı.

### 3.6 Disk temizliği (2026-11-01)

- Silinenler: repo `.build` (31 GB; eski test kopyaları, out, portable app),
  `/tmp/pear-*` test klonları (~2.2 GB), `ms-playwright`, `pip`, `node-gyp`
  cache'leri (~680 MB). Küçük teşhis betikleri `build/diagnostics/` altına alındı.
- Korundu: `~/Library/Application Support/PearSilicon` (oyun verisi 32 GB dahil),
  `Engines`, `Applications`, `Downloads`, belgeler.
- Sonuç: `/System/Volumes/Data` boş alan **14 GB → 37 GB**.
- Not: oyun indirmesi sürerken oyun verisine dokunulmadı.

---

## 4. Sıradaki kesin adım

1. Kullanıcı Genshin'i yeniden başlattığında denetleyicinin çalıştığını doğrula:
   - `pearsilicon logs com.miHoYo.GenshinImpact` veya
     `~/Library/Application Support/PearSilicon/Logs/com.miHoYo.GenshinImpact.log`
     içinde `[PearRuntime][input] controller 'Pro Controller' reported as Xbox…`
     ve oyunun kendi `[MiHoYoGamepad] Gamepad connected:` satırı görünmeli.
   - Oyun içi kontrol testi (kullanıcı).
2. Stable kanal gerçekten kullanılacaksa GitHub'da **normal (prerelease olmayan)**
   bir release yayınlanmalı; şu an repoda yalnız `development-beta` var. Stable
   seçildiğinde "no stable release" hatası beklenir.
3. `swift build`, `swift test` (aşağıdaki sonuç) ve `./scripts/build-app.sh release`
   tekrar çalıştırılmalı; app paketi commit sonrası yeniden üretilebilir.
4. ~~Değişiklikleri commit + push et~~ → `7284687`, `fa98334` ve `e9535dc`
   push edildi; uygulama paketi `e9535dc` ile yeniden derlendi ve imzası doğrulandı.
5. Kullanıcı Genshin'i tamamen kapatıp yeniden açmalı (runtime + Info.plist
   güncellemeleri bir sonraki açılışta etkin). Ardından logda
   `controller 'Pro Controller' reported as Xbox…` ve oyunun
   `[MiHoYoGamepad] Gamepad connected:` satırı kontrol edilmeli.
6. Kullanıcı `/Applications/PearSilicon.app` (eski, çalışıyor) yerine
   `build/PearSilicon.app`'i açmalı; çalışan uygulama izinsiz kapatılmadı.

### Bilinen sınırlar / notlar

- Controller köprüsü **GCController kullanan** uygulamalara yarar. Yalnız dokunma
  girdisi kullanan ve GameController'a hiç bağlanmayan oyunlarda denetleyici
  girişi otomatik olarak dokunmaya çevrilmez; bu ayrı bir özellik olurdu.
- Kimlik normalizasyonu (Switch/generic → Xbox) varsayılan açıktır; uygulama
  Switch'e özel ikon/özellik bekliyorsa `PEAR_CONTROLLER_NATIVE=1` ile kapatılabilir.
- Genshin resmi iOS listesi Xbox / Xbox Elite / DualShock 4'tür; Switch Pro bu
  nedenle normalde yok sayılıyordu, köprü bunu aşar.
- Oyun çalışırken runtime dosyası değiştirildi; mevcut süreç eski runtime'ı
  kullanmaya devam eder, bir sonraki açılış yenisini yükler.
- Community indirme GitHub API rate limitine takılırsa repo ZIP'ine düşer;
  bu durumda release yerine kaynak ağacı indirilmiş olur.
- WineHQ Stable seçeneği UI'dan kaldırıldı; servis kodu (`.stable`) geriye dönük
  testler için duruyor.

---

## 5. Gerçek ortam / kütüphane düzeni

```
~/Library/Application Support/PearSilicon/
  ios-apps/com.miHoYo.GenshinImpact.app/   (Frameworks/libPearRuntime.dylib güncellendi)
  Applications/jp.co.bandainamcoent.BNEI0402.app
  wine-apps/DELTARUNE/                     (DXVK prefix + backup)
  Engines/wine-staging-11-21/
    Runtime/  Graphics/DXMT/  Graphics/DXVK/
  Games/com.miHoYo.GenshinImpact/          (32 GB oyun verisi — DOKUNMA)
  Logs/, Keymaps/, Keychain/, ODR/
```

- DELTARUNE manifest: `graphicsBackend: "moltenvk"` (DXVK).
- Genshin: iOS app, `ios-apps` altında; runtime kopyası güncellendi.
- Wine motoru `wine-staging-11-21`; DXVK pinli 1.10.3 kurulu.

---

## 6. Doğrulama durumu

| Alan | Durum |
| --- | --- |
| `swift build` | temiz |
| `swift test` | **289 XCTest + 24 Swift Testing, 0 hata, 15 opsiyonel skip** (0.4.3 UI derlemesi sonrası yeniden koşuldu) |
| Development release | **`v0.4.3`** (ayrı release), asset `PearSilicon.zip` (2.32 MB), SHA-256 `14b5c8d6…`; eski `development-beta` 0.4.2 olarak korunuyor |
| Web sitesi | güncellendi ve `main`'e push edildi (`6e25918`, Cloudflare Pages otomatik dağıtım) |
| Güncelleme kanalları | liste tabanlı seçim testleri ✓ |
| Community GitHub | URL ayrıştırma + gerçek repo çözümleme testi ✓ |
| Motor kaldırma | birim testi ✓ |
| KosmicKrisp kaldırma | derleme + testler ✓ |
| Controller kimlik/replay | Catalyst probe ile doğrulandı ✓ |
| Controller/Genshin | oyun kendi GameController katmanını Mac'te başlatmıyor; pad→keymapper köprüsü kurulu, kullanıcı testi bekliyor |
| DXVK/DELTARUNE | önceki oturumda görsel olarak doğrulandı |
| Disk temizliği | 14 GB → 37 GB boş alan |

---

## 7. Çalışma kuralları (koru)

- **Türkçe** yanıt ver.
- Release/tag yayınlanmayacak; yalnız `feature/portable-multiplatform` dalına push.
- Ekran görüntüsü alma, masaüstü otomasyonu, odak çalma, otomatik tıklama yok.
- Kullanıcının açık oyununu/app'ini izinsiz kapatma.
- Özellik tamamen uçtan uca doğrulanmadan "çalışıyor" denmeyecek.
- Prefix'te `Z:` veya mutlak host linki oluşturma; entry-içi göreceli link kullan.
- `sandbox-exec` Wine'ı sarmak için kullanılmayacak (Rosetta/wineserver kırılıyor).
- `wineboot` argümanı `-u`; `pkgutil` yolu `/usr/sbin/pkgutil`.
- Kullanıcı klasörleri: `/Volumes/Untitled` (APFS), `/Volumes/Untitled 1` (exFAT).

## 8. Bilinen sınırlamalar

- DXVK 1.10.3 (2023) macOS yaması; DXVK 2+/3+ MoltenVK'da geometry shader
  olmadığı için çalışmaz.
- DXMT, winemac Metal view API'sini export eden Wine derlemesi gerektirir;
  otomatik Gcenx motorlarında reddedilir (siyah ekran yerine net hata).
- Mac uygulamaları native çalışır; izolasyon yok.
- Wine VM değildir; kernel anti-cheat çalışmaz; Rosetta 2 gerekir.
- Yedekler şifresiz; uygulama ad-hoc imzalı, noterize değil.
- Controller köprüsü yalnız GameController kullanan uygulamalarda etkilidir.

## 9. 2026-11-02 — 0.4.5 regresyon düzeltmesi

0.4.5 (`da96a2f`) tüm iOS uygulamalarında ilk fare olayında SIGSEGV üretiyordu.
Kök neden ve düzeltmeler:

- **`InstallNativeTouchTracking` imzası:** `imp_implementationWithBlock`
  blokları `(self, ...metot argümanları)` alır; SEL geçirilmez. Blokta fazladan
  `SEL _cmd` parametresi vardı, bu yüzden `event` çöp bir işaretçiye düşüyor ve
  `-[UIApplication sendEvent:]` çöp olayla çağrılıyordu. Blok artık
  `^(id self, id event)` ve orijinal IMP'ye yakalanan `sel` veriliyor.
  (Red, SLIMEIM, Gutterball çökmeleri bunun kanıtıydı.)
- **Fare→dokunma yedeği artık varsayılan kapalı:** her tıklamada sentetik dokunma
  üretiyordu; modern uygulamalarda tek tıklamayı çift tıklamaya çeviriyordu.
  Yalnız `PEAR_MOUSE_TOUCH=1` ile açılır.
- **`ActivateMainWindow`:** `activateIgnoringOtherApps:` ve `center` kaldırıldı
  (odak çalma yok). Pencere 1/2.5/5 sn'de yeniden denenir, en büyük görünür
  NSWindow `makeKeyAndOrderFront:` + `makeKeyWindow` ile anahtar yapılır; UIWindow
  yalnız anahtar değilse `makeKeyAndVisible` çağrılır. Tıklamaların pencereye
  ulaşması için gerekli.
- **`PearIsLegacyApp()`:** eski-SDK (pre-15, sahne manifesti yok) koşulu tek
  yerde toplandı; `InstallLegacyWindowFix` bunu kullanıyor.
- **Sanal digitizer:** anahtar pencere/`contextId` yoksa artık oluşturulmuyor
  (bozuk koleksiyon UIKit'i çökertiyordu); `_spinLock` ivar'ı yoksa kilit
  alınmıyor.

Doğrulama (arka planda, odak çalmadan, `pearsilicon launch --background`):
Riptide GP2, Minecraft, Gutterball ve SLIME IM açıldı; yeni çökme raporu yok.
Gutterball penceresi oluştu ve `sample` çıktısında Metal draw call'ları görüldü
(artık beyaz ekran değil). `swift build`, `swift test` (24 Swift Testing) ve
`./scripts/build-app.sh release` temiz.

Not: `build/PearSilicon.app` 0.4.5 (17) sabit runtime ile yeniden üretildi.
Kurulu `ios-apps/*` runtime'ları elle güncellendi ve yeniden imzalandı. Eski
0.4.4 runtime'ına dönmemek için Settings → "Refresh iOS Runtimes Now"
kullanılmamalı; yeni app paketi kullanılmalı.

## 10. 2026-11-06 incelemesi

- Bu çalışma ağacında ana pencerenin açık görünümde koyu kalan arka planı, ayırıcıları ve seçim renkleri sistem temasına uyarlandı. Arama sonuçsuzken kurulum önerisi yerine sonuç bulunamadığı gösteriliyor.
- ServicesShim günlüklerinde önceden biçimlendirilmiş metnin tekrar biçim dizgesi olarak kullanılması düzeltildi.
- `swift test` değişikliklerden önce başarılı; `swift build` arayüz değişikliklerinden sonra başarılı. Runtime yeniden derlendi.
- Cut the Rope IPA ön kontrolü, kurulum ve arka planda 12 saniyelik süreç başlatma/durdurma testini geçti. Bu, görsel veya oynanış doğrulaması değildir.
- Dr. Driving IPA ön kontrolü, kurulum ve arka planda 12 saniyelik süreç başlatma/durdurma testini geçti. Angry Birds HD 1.5.0 desteklenmeyen CPU mimarisi nedeniyle ön kontrolde reddedildi.
- Eski durum belgesindeki kurulu oyunlar ve günlükler bu çalışma ortamında mevcut değildi. Tüm oyunlar ve shimler uçtan uca doğrulanmış değildir; açık/koyu görünümün görsel kontrolü ve oyun içi testler hâlâ gereklidir.

## 11. 2026-11-06 — giriş, IPA ve grafik incelemesi

- GTA Vice City için kayıtlı pointer lock tercihi kapatıldı; yeni oyunlarda varsayılan kapalı, açıkça kaydedilmiş tercihler korunur.
- Fare-dokunma yedeği ayrı `MouseTouchShim.mm` modülünde oyun başına isteğe bağlıdır; basma/sürükleme/bırakma, yerel dokunma bekleme süresi ve odak kaybında bırakma eklenmiştir. Cut the Rope için tercih açıldı.
- Legacy GL dokunma dönüşümü yalnız gerçek görüntü ölçeklemesi etkinken uygulanır. `scripts/touch-geometry-smoke.mm` küçük/büyük/kenar boşluklu geometriyi kontrol eder; oyun içi dokunma testi değildir.
- Metal geçici 1920×1080 değerleri, yalnız shim tarafından konulmuş ve oyun tarafından değiştirilmemişse gerçek katman boyutuna güncellenir. Tam ekran, iç çözünürlük ve Metal HUD görsel olarak henüz doğrulanmadı.
- ZIP64 adresi taşması ve ZIP yorumunda bitiş imzası bulunması durumları düzeltildi. Birden fazla app içeren IPA belirsiz sayılarak reddedilir; hasarlı, şifreli veya desteklenmeyen mimarili tüm IPA'ların çalışacağı iddia edilemez.
- İzole Cut the Rope, GTA ve eski iOS 10 SDK’lı Gutterball IPA kurulumları ve süreç testleri geçti. Kullanıcı Cut the Rope fare tıklama/sürükleme ile GTA imleç serbestliğini doğruladı. Gutterball için kullanıcı kontrolü sürüyor; HUD görsel olarak doğrulanmadı.
- Legacy pencere davranışı `LegacyWindowShim.mm` içine ayrıldı; pencere düzeltmesi ana döngüden önce denenir ve sınıf geç yüklenirse yeniden denenir. Sahnesiz uygulamalarda ekran, GL ve sanal dokunma aynı uygulama-delegate penceresini kullanır.
- iOS 17 öncesi SDK ile derlenen ve `UIApplicationSupportsIndirectInputEvents` belirtmeyen uygulamalarda önceki doğrudan dokunma varsayılanı korunur; açık tercihler ve bilinmeyen SDK'lar değiştirilmez. Bu politika test edildi.
- Gutterball ilk kullanıcı denemesinde eski runtime ile `_setContentMinSizeFromScene` hatasıyla çöktü; runtime güncellendi ve arka plan süreç testi geçti. Son kullanıcı geri bildirimi hâlâ açılmadığı yönündedir; son denemeye ait yeni süreç/çökme kaydı görülmediğinden başlatıcı mesajı araştırılıyor. Başarı iddia edilmemelidir.

## 12. 2026-11-07 — devam eden doğrulama

- Gutterball'da boş uyarı paneli ve 0×0 native pencere ayrı sorunlar olarak saptandı. Alert/glass yerleşimi korunuyor; yalnız boş legacy host penceresine başlangıç boyutu veriliyor.
- Deneysel legacy katman bağlantısı görüntüyü getirdi. Doğrudan yerel legacy dokunma köprüsü için kullanıcı tıklamanın çalıştığını doğruladı. Ölçekleme hâlâ kullanıcı testinde sorunlu; sabit mantıksal çözünürlük ve doğrudan UIWindow katmanı seçenekleri deneniyor. Başarı genelleştirilmemeli.
- Deneysel sanal gamepad modülü public GameController API'siyle yazıldı. İzole IPA testinde hidden virtual controller bağlandı; fiziksel klavye/fare ve native pointer-lock ile oyun içi kontrol henüz doğrulanmadı. Oyun bazında GUI seçeneği eklendi.
- Bu makine M1; M5/M6 test edilmedi. Kısa Gutterball menü performans kaydı yaklaşık 33.34 ms ortanca sunum aralığı gösterdi. GPU yolu hatası sonucu çıkarılmadı. Ayrıntılar `docs/COMPATIBILITY_RESEARCH.md`.
- Bu oturumdaki değişiklikler henüz commit/push/release yapılmadı. Son Swift test turu 296 XCTest + 24 Swift Testing, 0 hata, 16 skip; yeni runtime yollarının tümü uçtan uca doğrulanmış değildir.

### 2026-11-07 — kalıcı profil kurulumu

- Kullanıcı önceki denemede Gutterball tıklama/sürükleme ve başlık çubuğundan taşımanın çalıştığını doğruladı. Legacy profil ve 1024×768 iç çözünürlük tercihi kalıcı kaydedildi; GUI'ye deneysel legacy profil ve klavye/fare → sanal gamepad seçenekleri eklendi.
- Güncel yerel uygulama `/Applications/PearSilicon.app` içine kuruldu; önceki kopya `build/Backups/PearSilicon-before-input-update-20261107-072049.app` altında. Bu yeni bir yayın değildir.
- Normal kurulumdan yeniden başlatmada kullanıcı giriş sorununun tekrarlandığını bildirdi. Günlükte kök görünümü olmayan ikinci UIKit penceresi key oluyor. `PearPrimaryWindow` artık içeriksiz key pencereyi oyun penceresinin önüne koymuyor. Düzeltme kurulu uygulamaya ve Gutterball runtime'ına aktarıldı; normal başlatma sonrasında kullanıcı tıklama, sürükleme ve pencere boyutlandırma denemesi için **“sorunsuz çalışıyor”** geri bildirimi verdi. Bu doğrulama Gutterball'ın mevcut profili içindir; diğer oyunlara genellenmez.
- Son Swift turu: **299 XCTest + 24 Swift Testing, 16 skip, 0 hata**. Runtime yeniden derlendi. Tüm oyunlar, Retina/HUD ve M5/M6 donanımı için genel başarı iddiası yok.

### 2026-11-07 — diğer oyunlar ve GTA sanal gamepad

- Run Sackboy Run, ayrı geçici kütüphanede güncel runtime ve legacy 1024×768 profiliyle kurulum/12 saniye süreç/nonempty pencere testini geçti. Kullanıcı ayrıca “sorunsuz çalıştı” bildirdi. Testin kendi geçici süreci ve kütüphanesi temizlendi; kullanıcı kayıtları değiştirilmedi.
- GTA Vice City güncel runtime ile sanal gamepad modunda başlatıldı. Gerçek günlükte `connected=1`, keyboard/mouse connected ve `capture requested=1 foreground=1 available=1 locked=1` görüldü. Gerçek kullanıcı klavye olayları sol çubuk ve A/Menu değerlerine ulaşıyor. Oyun içi hareket/kamera ve yeniden boyutlandırma sonucu bekleniyor.
- Sanal gamepad sağ çubuğu, native capture kaybedildiğinde artık hemen nötrleniyor. İsteğe bağlı `PEAR_DEBUG_POINTER` yalnız kontrol değerlerini ve capture durum değişimini kaydediyor.
- Geometri smoke testi yeniden geçti. Native yakalama için cursor warp veya dokunma mouse-look eklenmedi.
- GTA kullanıcı testi: klavye çalışıyor, fare/kamera çalışmıyor. Yakalama son kullanıcı olaylarında Esc ile kapatılmış (`requested=0 locked=0`); açık yakalamayla tekrar kontrol istendi. Bu nedenle GTA mouse-look doğrulanmış sayılmıyor. Ham mouse örnekleri/ kabul sayısı ve sanal sağ çubuk readback tanılaması hazırlandı; sonraki runtime yüklemesinde etkin olacak.
- Cut the Rope ve Dr. Driving güncel runtime ile ayrı geçici kütüphanelerde başlatma/nonempty pencere testlerini geçti; bu son testler görsel ölçekleme doğrulaması değildir.

### 2026-11-07 — yön uyumu ve odak sonrası capture

- Dr. Driving ekran görüntüsündeki kırpmanın kaynağı: GL drawable 320×480, viewport 480×320. Yalnız tek yön ailesi bildiren GL uygulamalarında ilk drawable bu bildirimle hizalanıyor; karışık/eksik bildirimler korunuyor. Tahmin yerine gerçek renderbuffer boyutu sorgulanıyor. Yeni günlükte renderbuffer ve viewport **480×320**; kullanıcı büyütme/küçültme, görüntü ve tıklamalar için **“Görüntü ve tıklamalar düzgün”** doğrulaması verdi.
- GTA'da kullanıcı native yakalamayla kamera hareketinin çalıştığını, Command-Tab sonrası kaybolduğunu bildirdi. Capture isteği, odak nedeniyle askıya alınma ve Escape basma kenarı ayrı durumda tutuldu; çift key-down aynı isteği iki kez çevirmiyor. AppKit ve UIKit odak bildirimlerinde tercih iki yönde geçersiz kılınıyor; oyun içi ilk tıklama capture'ı yeniden istiyor ve o tıklamayı ateş/dokunma olarak göndermiyor. Yeni oyun içi odak turu bekleniyor.
- Yeni durum testi (`scripts/pointer-capture-state-smoke.cpp`) odak turu, Escape ile bırakma ve tıklamayla geri alma durumlarını geçti. Geometri testi yön düzeltmesi/karışık yönleri de kapsıyor. İlgili Swift regresyon turu **29 test, 0 hata**.
- Minecraft güncel runtime ile ayrı kütüphanede başlatma/nonempty pencere testini geçti; görsel ölçekleme bu testten çıkarılamaz.
- Güncel yerel uygulama /Applications'a yeniden kuruldu; önceki sürüm `build/Backups/PearSilicon-before-focus-orientation-20261107-074032.app` altında. Oyun verileri korunuyor; yeni commit/push/release yok.
- GTA'nın sonraki tanılamasında ham fare örnekleri geliyor, ancak native `locked=0` olduğundan kabul edilmiyor. Yeniden yakalama için eklenen local monitor ilk tıklamayı tüketiyordu; UIKit'in native etkinleştirme hareketini görmesi için bu ilk basma/bırakma çifti artık aynen iletiliyor (bir önceki maddede yazan tüketme davranışı kaldırıldı). Bu düzeltmenin oyun içi doğrulaması bekleniyor.

### 2026-11-07 — yapılandırılabilir klavye/fare → sanal gamepad

- `Enable keymapper` ayrı tutuldu. Keymap sekmesine bağımsız **Keyboard Mouse to Gamepad Inputs** anahtarı eklendi. Açıkken oyun gizli `GCVirtualController` görür; dokunma keymapper'ı ve native pointer lock istenmez. Keymapper anahtarı kapalıyken de bu mod çalışır.
- A/B/X/Y, L1/R1, L2/R2, D-pad, MENU/OPTIONS, L3/R3 ve sol çubuk yönleri ayrı ayrı tuşa veya fare düğmesine atanabilir; fare hassasiyeti 0,2–3 arasında ayarlanır ve dikey bakış yönü ters çevrilebilir. Tuş yakalama alanında Escape atamayı iptal eder.
- Eşleme oyun başına `virtualGamepad.map.<bundle>` altında JSON saklanır ve başlatmada `PEAR_VIRTUAL_GAMEPAD_MAP` ile runtime'a geçer. GUI ve CLI aynı kayıtlı ayarı kullanır; değişiklik bir sonraki başlatmada etkili olur. `PEAR_VIRTUAL_GAMEPAD` ve eşleme değişkeni oyunlar arasında sızmaz.
- Fare yakalama artık oyunun native pointer lock'una bağlı değil: oyun penceresindeki ilk sol tıklama `CGAssociateMouseAndMouseCursorPosition(false)` ve imleç gizleme ile yakalar ve o tıklamayı oyuna iletir. Escape bırakır; ikinci Escape yeniden yakalamaz. Capture açıkken GCMouse ham örnekleri kabul edilir, NSEvent deltaları yedek yoldur. Odak kaybı capture'ı bırakır, oyuna dönüşte otomatik geri gelir; çıkışta imleç ve ilişkilendirme geri yüklenir.
- Düzeltilen gerçek hatalar: `input ?? .none` ifadesinin `Optional.none` seçip varsayılan atamayı geri getirmesi; D-pad tuşlarının tekrar denetimine girmemesi; ikinci Escape'in yakalamayı yeniden açması.
- Doğrulanan: `swift build`, `swift test` (**307 XCTest + 24 Swift Testing, 16 skip, 0 hata**), `./runtime/build.sh`, `./scripts/build-app.sh release` ve capture state smoke testi geçti. Yeni eşleme modeli için 8 test eklendi. GTA Vice City'de fare/kamera, tuş eşlemeleri ve odak dönüşü **kullanıcı oyun içi testi bekliyor**; bu satır o testin sonucu değildir.

### 2026-11-08 — otomatik uyumluluk ve arayüz yenilemesi

- Legacy pencere köprüsü ve fare→dokunma yedeği artık oyun başına otomatik algılanıyor. Algılama runtime'daki `PearIsLegacyApp()` kuralını aynı şekilde uygular: `UIApplicationSceneManifest` yok ve `DTSDKName` ana sürümü 15'ten küçük. `AppCompatibility` plist okumasını yol + değişiklik tarihi ile önbelleğe alır.
- GUI'deki Legacy/Mouse-to-touch anahtarları ve çözünürlük seçici kaldırıldı. Detay sayfasındaki salt-okunur **Compatibility** kartı profili ve etkin durumu gösterir; kayıtlı bir manuel değer varsa **Use automatic** ile temizlenebilir. Mevcut `legacyBridge.*` ve `mouseTouch.*` kayıtları korunur, böylece kullanıcı ayarları kaybolmaz.
- CLI aynı yolu kullanır: `pearsilicon compat <id> [--json]`, `pearsilicon legacy <id> [on|off|auto]`, `pearsilicon mousetouch <id> [on|off|auto]`. `launch` artık `AppCompatibility.detect` + `compatibilityEnvironment` çağırır.
- GUI yenilemesi: uygulama içi Pear logosu ve boş durum ekranı, Yeniden boyutlandırılabilir iki sütunlu detay sayfası, cam sekme çubuğu, durum rozetleri, **Settings → About** sekmesi. Sabit 260 pt Actions sütununun yol açtığı kırpma giderildi; test amaçlı sürüklenebilir platform anahtarı kaldırılarak pencere yerleşimi sabitlendi.
- Doğrulanan: `swift build`, `swift test` (**311 XCTest + 24 Swift Testing, 16 skip, 0 hata**), yeni `AppCompatibility` algılama testleri (4 dosya senaryosu), `./scripts/build-app.sh release`.

