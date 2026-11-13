# PearSilicon — Çalışma Durumu

> **DEVİR NOTU — 2026-11-13:** Kullanıcı kalan işi başka ajana devrediyor. Son hedef: GL/EAGL yolu tamamen ANGLE; sistem OpenGLES bağımlılığı/fallback kaldırılacak. Yeni exclusive geçiş **WIP**, bitmedi; 45 kurucu testinde 1 hata açık. Önce belgenin sonundaki **“Sonraki ajana devir — tamamen ANGLE”** bölümünü oku. Çalışan önceki checkpoint `fd11163` / runtime `26096cc`.

> Güncel çalışma — 2026-11-13: `codex/angle-metal-bridge`. Opt-in GL/EAGL import ve dinamik çağrı yönlendirmesi eklendi. Kullanıcı ayrı test kopyalarında Cut the Rope için küçük/tam ekran + dokunmayı, Minecraft için görüntü/giriş/native fare yakalamayı doğruladı. Minecraft native Metal kullanıyor; Metal→ANGLE çevirisi iddiası yok. Normal kurulumlar otomatik değiştirilmedi. Ayrıntılar belgenin sonunda ve `docs/ANGLE_INTEGRATION.md` içinde; önceki bölümler tarihsel kayıttır.

## 0.8.3 (28) — 2026-11-11

- **Wine kataloğu:** MetalSharp Wine ve Sikarugir Wine 11 kaldırıldı (PearWine
  zaten MetalSharp tabanlı). Liste: PearWine → WhiskyWine → WineHQ Staging/Devel.
  WhiskyWine kaynağı (Sikarugir-App/Engines) çalışıyor; Whisky'nin kendi adresi
  (data.getwhisky.app) 404. GitHub API'nin anonim 60/saat sınırı dolunca kurulum
  403 ile düşüyordu → herkese açık sürüm sayfalarına (releases.atom +
  expanded_assets) geri dönüş eklendi; aynı dosya/URL/SHA-256 canlı doğrulandı.
- **Rosetta tespiti düzeltildi:** `/Library/Apple/usr/libexec/oah` klasörü
  yalnız RosettaLinux içerebiliyor; artık `oah/libRosettaRuntime` aranıyor.
  x86_64 motorlar (WhiskyWine, WineHQ) Rosetta yokken indirilmeden açık mesaj
  veriyor. Bu Mac'te Rosetta 2 kurulu değil.
- **iOS runtime otomatik yenileme:** PearSilicon güncellenince (paketteki runtime
  parmak izi değişince) açılışta arka planda yenileniyor; sol altta ilerleme
  çubuğu, pencere kullanılabilir (ana iş parçacığı olay döngüsünde doğrulandı),
  yenileme bitene kadar yalnız iOS uygulamaları açılamıyor/kurulamıyor/silinemiyor.
  Hazırlama (ditto/codesign) ana iş parçacığından çıkarıldı.
- **Yakınsama hatası düzeltildi:** runtime karşılaştırması ham baytlarla
  yapılıyordu; kurucu her uygulamada runtime'ı yeniden imzaladığı için yenilenen
  uygulama hep "eski" görünüyordu (her elle yenilemede 3,4 GB Genshin yeniden
  işleniyordu). Artık imzasız içerik karşılaştırılıyor, isteğe bağlı bileşenler
  (libcxxcompat, MarketplaceKit) uygulamada yoksa yok sayılıyor. Gerçek
  uygulamalarda "already current" ~1 sn.
- **32-bit FPS göstergesi:** motor ANGLE/Metal ile çizdiği için Metal HUD
  çalışıyor; motorun sarı FPS katmanı artık açılmıyor, tek gösterge.
- **Log oturumları:** LaunchServices ile açılan iOS oyunlarında da her açılış yeni
  log, önceki `<id>.1.log`.
- **PearLegacyEngine `9aadb01d`:** JIT (C++) artık `-mcpu=apple-m1` ile derleniyor
  (Rust tarafı zaten öyleydi). PearWine imzalı/notarize üst akış uygulaması
  olduğundan ikili değişiklik yapılamaz (32-bit yetkisi bozulur).
- **Uçtan uca test:** 338 XCTest (22 isteğe bağlı canlı test) + 24 Swift Testing,
  PearDebug 7, PearRuntime derleme; canlı: PearWine kurulumu (GitHub'dan),
  WhiskyWine kurulum/arama, GTA VC exe kabulü (3/3) ve içe aktarma, gerçek
  launcher ile GTA VC'nin PearWine üzerinde açılıp kapanması, GTA VC DE (iOS) ve
  Miku Flick (32-bit) CLI ile açma/durdurma, GUI otomatik runtime yenileme.
  Görsel oynanabilirlik ve GUI tıklamaları elle doğrulanmadı.
- Mac uygulaması verilerinin kopyalanması kullanıcı isteğiyle yapılmadı.

## Oturum 2026-11-11 — PearRuntime/PearWine/PearDebug ayrımı, gamepad, Miku Flick

### 0.8.1 — PearWine kurulumu (2026-11-11)
- PearWine kurulumu "no complete Wine runtime with bin/wine64" hatasıyla
  düşüyordu: MetalSharp/PearWine'da `bin/wine` 365 baytlık bir kabuk
  sarmalayıcısı (GStreamer/MoltenVK yollarını ayarlayıp `bin/wine-launcher`'ı
  çalıştırıyor). Kurucu artık sarmalayıcıyı değil yerel `bin/wine-launcher`'ı
  kaydediyor (`wine64` > `wine` > `wine-launcher`), sarmalayıcının dışa aktardığı
  `GST_PLUGIN_SYSTEM_PATH_1_0` / `GST_PLUGIN_SCANNER_1_0` değişkenleri
  ManagedAppService tarafından veriliyor (MoltenVK zaten veriliyordu).
- Uçtan uca doğrulandı (`PEAR_LIVE_PEARWINE_INSTALL=1` ile açılan canlı test,
  geçici depoya): indirme, SHA-256, yol denetimi, açma, overlay, kayıt ≈3,5 dk.
  `wine-launcher --version` → `wine-11.20 (MetalSharp Wine 6.0)`, `wineboot -i`
  tam prefix oluşturuyor.
- Settings → Wine'daki ayrı "Open-source Wine — automatic" bölümü kaldırıldı;
  WineHQ Staging/Development üstteki motor listesinde.

### Güncellemeler — eski sürüm gösterme hatası (0.8.0 ile düzeltildi)
- GUI her zaman Development Beta kanalını kullanıyor. Bu kanal GitHub listesindeki
  *ilk ön sürümü* seçiyordu ve kararlı sürümleri hiç görmüyordu: v0.7.0
  kararlı olduğu için kullanıcılara daha eski **v0.6.0** sunuluyordu. Kanal
  ayrıca yalnız hash karşılaştırdığı için sürüm düşürmeyi de "güncelleme"
  sayabiliyordu.
- Düzeltme: geliştirme kanalı artık kararlı + ön sürümler arasında en yüksek
  sürüm numarasını seçiyor (`v0.8.0-beta` gibi ekli etiketler kendi sürümüyle
  sıralanır, eşitlikte kararlı sürüm kazanır); her kanalda daha eski sürüm asla
  güncelleme olarak sunulmuyor. `AppUpdateChannelTests` (6 test) eklendi.
- Eski sürümlerden geçiş: eski istemciler geliştirme kanalında en yeni oluşturulan
  *ön sürümü* aldığı için 0.8.0 ile aynı ZIP `v0.8.0-beta` ön sürüm etiketiyle
  de yayınlanıyor (kararlı `v0.8.0`'dan sonra oluşturulur). Yeni istemciler
  `v0.8.0`'ı seçer. Bundan sonraki sürümlerde de bu eşlik eden ön sürüm
  etiketi, eski istemciler (≤0.7.0) için yayınlanmaya devam etmeli.

### Yeni depolar (GitHub, herkese açık)
- **PearRuntime** (`denizomer10/PearRuntime`, `runtime/` alt modülü): `runtime/`
  geçmişiyle ayrıldı. Kaynaklar `modules/{core,input,graphics,device,storage,services}`
  altında; her modül açılışta `PEAR_RUNTIME_DISABLE` / `PEAR_RUNTIME_ONLY` ile
  kapatılabilir. Derleme artık `-O2 -mcpu=apple-m1` (önceden optimizasyonsuzdu),
  modüller paralel derleniyor, `-dead_strip`. Sürüm 0.8.0.
- **PearDebug** (`denizomer10/PearDebug`, `Vendor/PearDebug` alt modülü):
  `PearDebugKit` (LogStore oturum/rotasyon, LogParser, kural modülleriyle
  Analyzer, CrashReports, PearLegacyEngine için GDB istemcisi `LegacyProbe`) ve
  `peardebug` CLI. PearSilicon'un tüm açılış logları artık PearDebug oturumu
  (önceki çalışma `<id>….1.log` olarak saklanır). `pearsilicon analyze <app>` eklendi.
- **PearWine** (`denizomer10/PearWine`, v1.0.0): MetalSharp Wine 6.0 (arm64,
  Wine 11.20 + FEX) tabanı SHA-256 ile sabitlenmiş manifest + PearWine overlay
  (`pearwine.env`, `pearwine-defaults.reg`). WineHQ 11.21 birleştirmeli kaynak
  derleme hattı ve CI hazır, **henüz çalıştırılmadı**.

### PearSilicon
- Wine dağıtım kataloğu (`WineDistributions.swift`): PearWine (önerilen) →
  MetalSharp Wine → Sikarugir Wine 11 → WhiskyWine → WineHQ Staging/Devel.
  Motor seçilmemiş Windows oyunu açılınca seçici çıkar; PearWine kuruluysa
  otomatik kullanılır; oyun 20 sn içinde hata ile kapanırsa ayrıntı panelinde
  "Try <sonraki motor>" düğmesi çıkar. Settings → Wine'da katalog listesi var.
- PearWine ortam varsayılanları başlatmada uygulanır (ayarlı değerleri ezmez);
  prefix ilk oluşturulunca `pearwine-defaults.reg` C: üzerinden içe aktarılır.
- Testler: 314 XCTest (16 atlandı) + 24 Swift Testing + 5 yeni
  `WineDistributionTests`, 0 hata. PearWine'ın 962 MB'lık gerçek kurulumu uçtan
  uca denenmedi (yalnız overlay hash'i yayınlanan dosyayla doğrulandı).

### Gamepad (Genshin, GTA VC DE)
- Kök neden: runtime açılıştan 3 sn sonra `GCControllerDidConnectNotification`
  bildirimini tüm gözlemcilere yeniden gönderiyordu. Denetleyiciyi zaten
  listeleyen Unreal/Unity motorları aynı kolu ikinci oyuncu yuvasına koyuyor,
  tek oyunculu oyun girdiyi yok sayıyordu. Ayrıca her boş `controllers`
  sorgusu ana iş parçacığını 1,2 sn kilitliyordu.
- Düzeltme (PearRuntime 0.8.0): kaçırılan bağlanma yalnız geç kaydolan ve kolu
  görmemiş gözlemciye bir kez iletilir; sorgu beklemesi yalnız ilk 1,5 sn ve
  ana iş parçacığında; oyun kendi denetleyici yolunu kullanınca pad→dokunma
  çevirisi kapanır (`PEAR_CONTROLLER_KEYMAP=force` ile açık tutulur); oyunun
  pad işleyicisi pad başına saklanır; vendorName logu pad başına bir kez.
- Doğrulama: Catalyst sonda uygulaması (sanal denetleyici). Eski runtime:
  listeleyen motor modunda 1 kopya bağlanma. Yeni: 0 kopya; geç gözlemci tam 1.
  Gerçek oyunlarda (fiziksel kol ile) kullanıcı testi bekliyor.

### Miku Flick şarkı sonu siyah ekran (düzeltildi)
- Oyun kare sunmaya devam ediyor ama siyah; CRI Mana film oynatıcısının
  PLAYEND olmasını bekliyor. İç `criMvPly` şarkı sonunda PLAYEND (6) oluyor,
  dosya kapanmış, Atom ses sesi bitmiş (durum 4); ancak `CriMvEasyPlayer`
  `executeWaitStatusServer` içindeki bitiş-zamanı kontrolü
  (`0x7dae8`: oynatma saati ≥ (kare+1)/fps) hiç geçmiyor, temizlik başlamıyor,
  dış durum PLAYING (5) kalıyor.
- Ölçüm: "VOC@LOID in Love" (`koi_suru_vocaroid_small.usm`) videosu 3677 kare
  @ 20 fps = 183,9 sn; müzik oyunda 2:56 (≈176 sn, kullanıcı ölçümü). Saat
  sesten sürüldüğü için ses bitince ≈176 sn'de takılıyor, 183,9'a hiç
  ulaşmıyor.
- Düzeltme (PearLegacyEngine `99c6c6d5`, `src/game_fixes.rs`): yükleme
  anında `__text` içinde tam bayt imzasıyla (tek eşleşme şartı) bulunan bu
  `ble`, koşulsuz `b` yapılıyor. Kullanıcı testinde şarkıdan sonra sonuç ekranı
  geldi. Miku Flick 02 (CRI Mana 1.61) bu kalıbı içermiyor, değişmiyor.
- Motorun `cargo test` entegrasyon testi bu makinede test uygulamasını
  derlerken (`ld: can't re-map file … libstdc++.6.0.9.dylib` armv6) düşüyor;
  motor kodundan bağımsız araç zinciri sorunu. 37 birim testi geçiyor.
- PearSilicon paketine yeni motor için `scripts/setup-legacy-engine.sh` ve
  `scripts/build-app.sh release` yeniden çalıştırılmalı.
- Motor: GDB sunucusunda `H` komutu iş parçacığı kimliğini onluk okuyup
  çöküyordu (protokol onaltılık) → düzeltildi. `D` (detach) yoktu ve bağlantı
  kopunca motor panikliyordu → artık oyun kaldığı yerden devam ediyor. Ana döngüdeki 5 `env::var`
  çağrısı `LazyLock`'a alındı. Bunlar PearLegacyEngine'de commit edilmedi.

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
  Yayın: https://github.com/denizomer10/PearSilicon/releases/tag/v0.7.0
- Dal temizliği: uzakta yalnızca `main` kaldı. `codex/pear-legacy-engine`,
  `denizomer10-pear-legacy-engine`, `denizomer10-virtual-gamepad-inputs`,
  `feature/portable-multiplatform` (hepsi `main` içinde) ve
  `denizomer10-reimagined-doodle` silindi. Sonuncusunun işlevleri `main`'de
  yeniden uygulandığı için birleştirilmedi; tarihsel kayıt
  `archive/reimagined-doodle` etiketinde (`3ba8d9c`) duruyor.
  PearLegacyEngine tarafında `experimental/angle`, `codex/miku-flick`,
  `codex/es2-port` silindi (`trunk` içinde).

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


### 2026-11-11 — Vice City and signed PearWine

- Fixed PE admission for Vice City's `.text` / SizeOfHeaders overlap while preserving raw section bounds checks. Three real EXEs admitted; full game folder imported.
- PearWine 1.0.1 uses the verified signed MetalSharp Wine ZIP, keeping its bundle and cross-architecture entitlement intact. Installed deep/strict signature verification passes. Defaults are outside the signed app.
- Fixed first-prefix initialization timeout and asynchronous registry-flush race. Fresh-prefix initialization and managed GTA Vice City process smoke test passed in 39 seconds. Visual gameplay is not verified: Computer Use permission is unavailable.
- Release: PearSilicon 0.8.2 (27), PearWine 1.0.1. Details and test evidence: `docs/VICE_CITY_PEARWINE.md`.

### 2026-11-12 — Miku Flick screen fit and touch

- PearLegacyEngine now honours `autoresizingMask` / `autoresizesSubviews` (decoded from nibs, applied on `setFrame:` / `setBounds:`). MikuFlick and MikuFlick 02 lay out their EAGLView at 320x460 inside a root view stretched to 320x480; the view stayed 460 pt tall, so the bottom row (わ key, pause button) was cut off and touches drifted. Renderbuffer is now 640x960 in both games; the user confirmed screen and touch are fixed.
- New engine diagnostics: `PEAR_TRACE_OPEN=1` logs every `open()`, and opening a directory is noted in the log.
- Verified: engine unit tests (41, incl. 4 new autoresize tests), Miku Flick title / music select / gameplay frames, Miku Flick 02 renderbuffer size. The engine's TestApp integration test fails while *building* the test app with the bundled clang (before the engine runs); unrelated to this change.
- Release: PearSilicon 0.8.4 (29), PearLegacyEngine 1a1c8a0f.

### 2026-11-12 — reliable, automatic updates (0.8.5)

- Cause of "The app's PearBuildCommit disagrees with the resolved release tag": the 0.8.4 ZIP was built before its commit, so the app embedded `8ed32e5` while `v0.8.4` points to `b55b987`. The updater's check is correct and stays strict.
- `scripts/publish-release.sh <notes.md>` is now the only release path: it refuses a dirty or unpushed tree or an existing tag, builds at HEAD, checks the built app's commit/version/build, ANGLE and signature, publishes `vX.Y.Z` + `vX.Y.Z-beta` at that exact commit, then downloads both assets and checks digest and embedded commit against the tags.
- Automatic updates (Settings → Updates → "Update automatically", on by default): check 15 s after launch and every 6 h, download and verify in the background, install with relaunch once no game/app is running and nothing is busy. Disabled for bare SwiftPM builds and with `PEAR_DISABLE_AUTO_UPDATE`.
- `apply-update` resolves App Translocation (a quarantined app runs from a read-only copy) to the real bundle, and its parent check uses the running copy's path. After installing, if the new app is quarantined, it opens System Settings → Privacy & Security and shows a dialog explaining "Open Anyway".
- Verified: 342 XCTests (22 skips) + 24 Swift Testing; `apply-update` on a scratch install with a quarantined staged build swapped atomically, kept a rollback, macOS blocked the new build, Privacy & Security and the guidance dialog appeared.

### 2026-11-12 — portable app data and removal choices

- Compatibility iOS HOME/temporary paths now use the selected library. Old native container data migrates into Games, with conflicts retained inside the library.
- GUI removal asks to keep saves or delete everything; iOS data, ODR, keychain, logs and legacy hosts are covered. Managed retained data restores on reinstall; Wine program-side saves are preserved with recovery copies.
- Settings General includes a confirmed clean-start reset for the current marked library. Running-app checks guard reset; previous storage copies remain separately removable.
- Full suite: 345 XCTest tests (22 optional skips), 24 backup tests, zero failures before the final added lifecycle case. Follow-up lifecycle/environment/migration tests: 15 passed. Live Genshin downloads and physical external-volume gameplay are not verified. No live save deletion/reset was performed.

- Marker fix: Clean start now runs the existing legacy-default-root adoption and validates the selected root before deleting any native-container data. Missing markers remain an error for custom roots. The existing local default library marker was repaired without resetting data. Eight lifecycle/storage tests passed.

### 2026-11-12 — Wine engine defaults and installer workflow

- Removed graphics picker and DXVK/DXMT install actions from Wine UI. GUI launches use engine defaults, retaining legacy metadata only for older packages.
- Recognized installers launch on import. Setup and installed EXE paths are separate, relative manifest fields. Prefix scans exclude system files/helpers, and ambiguous results open a choice sheet. Manual finish/rescan and Run as Installer cover unknown installers and setup-launched applications.
- Installer monitoring waits for the parent plus per-prefix wineserver idle; active installation participates in running-app guards. Only private C: and imported program targets pass launch validation.
- Targeted validation: 24 tests, one optional skip, zero failures, including synthetic import → bootstrapper/child → discovery → persisted EXE → application launch. No real Steam setup was run.

- Final Wine setup run: 350 XCTest tests (22 optional skips) plus 24 backup tests passed, zero failures.

### 2026-11-12 — PearWine removed; MetalSharp Wine is the default engine

- PearWine (separate repository, Python/Swift compatibility API, overlay, assessment, `wine-compat`) is removed from PearSilicon; the PearWine 2.0 plans are cancelled.
- Wine catalog: **MetalSharp Wine** (`metalsharp/MetalSharp-Wine`, signed `MetalSharp-Wine-*-arm64.zip`, GitHub SHA-256 checked) is the default; WineHQ Staging/Development are optional. WhiskyWine is no longer offered.
- Adding a Windows game (or launching one) with no engine installed downloads and installs MetalSharp automatically, with a progress bar at the bottom-left; the Settings detour is gone.
- MetalSharp defaults (msync, WINEDEBUG=-all, cursor confinement, GCMouse raw input, Option as Alt) are built in (`MetalSharpDefaults`) instead of an overlay.
- Existing "PearWine 1.0.1" engines are the same signed MetalSharp 6.0 app: they load as MetalSharp Wine 6.0 with the same engine ID, so games stay linked.
- Steam on MetalSharp starts as `C:\PearSiliconSteam\Steam.exe` (link to the Steam folder), avoiding MetalSharp's `\Steam\bin\cef\` launcher rule that crashed StorageService. A drive-letter alias was rejected: Steam saved the drive root as its install folder and asked to repair it on the next start. User confirmed Steam opened with the folder link.

### 2026-11-12 — Wine running state and force stop

- Running state of Wine entries comes from a 2-second scan of each prefix's processes (working directory inside the entry, or the prefix's wineserver folder `/tmp/.wine-<uid>/server-<dev>-<inode>`), so relaunched clients (Steam) and games started by a launcher show as running. Wine's background services alone do not count.
- Stop force-quits the whole prefix: `wineserver -k9` with the entry's engine (MetalSharp or WineHQ), then SIGKILL to anything left, including orphans. CLI: `wine-status <id>`, `wine-stop <id>`.
- Verified live with Vice City: all 10 prefix processes found, `gta-vc.exe` reported as the program, `wine-stop` cleared everything in 0.34 s.

### 2026-11-12 — PearDebug 0.2.0

- New PearDebug tools: `wine ps` (prefix processes; PearSilicon's running state and Stop now use PearDebugKit's `WineProcesses`), `steam` (Steam client diagnosis from its logs and registry), `legacy crash` (32-bit crash capture over --gdb), `legacy frames` (frame dumps to PNG + size summary), and analyzer rules for the problems found this session. Guide: `Vendor/PearDebug/DEBUGGING.md`.
- Verified live: Miku Flick dumps (640x920 before the fix, 640x960 after), Asphalt 6 crash (PC 0x70ee0, 11-frame chain), Steam drive-letter copy (drive-root repair loop), Vice City (`wine ps`/`wine-stop`).

### 2026-11-13 — Game Mode, native resolution and latency (0.8.8)

- **Game Mode (64-bit iOS):** installed apps declare `LSApplicationCategoryType` games, `LSSupportsGameMode`, `GCSupportsGameMode`, `CADisableMinimumFrameDurationOnPhone` and `LSAppNapIsDisabled` (`GameModeInfo`). Verified with GTA LCS in full screen: gamepolicyd "Found game … labelReason=LSSupportsGameMode", "Game mode status is now on".
- **Game Mode (32-bit):** four blockers fixed. The host bundle had the iOS bundle's ID (LaunchServices resolved it to the iOS record) → `com.pearsilicon.legacy.<id>`; symlinks out of the bundle broke its signature → removed, resources come from `PEAR_LEGACY_RESOURCES_DIR`/`PEAR_ANGLE_LIB_DIR`; `Process()` spawns were anonymous to RunningBoard → opened through LaunchServices, the engine writes its own log (`PEAR_LEGACY_LOG_FILE`); macOS labels native apps as games only inside an Applications folder → hosts live in `~/Applications/PearSilicon Games/<id>.app` (also shown in Launchpad/Games; removed on uninstall). Verified with Miku Flick: "Game mode status is now on".
- Per-app **Game Mode** (default on) and **Render Resolution** (native/75%/50%) settings → `PEAR_GAME_MODE`, `PEAR_RENDER_SCALE`.
- **PearRuntime 0.9.0:** `UIScreen.scale` reports the real backing scale (was 1.0 → quarter-resolution rendering on Retina); scale taken from NSScreen before the window exists (Catalyst's nominal 2.0 caused a mismatch on 1x displays). `WindowChromeShim` keeps the scene below the title bar (top HUD/banners were hidden and unclickable). Modern GL engines re-render at window size in maximised/full-screen windows (frozen 4:3 drawable gave pillar-boxing and blur); the freeze stays for the legacy profile. New `performance` module: latency-critical activity, QoS promotion of unqualified threads. Fewer per-frame main-thread dispatches and UIKit walks.
- **PearLegacyEngine:** HiDPI window; render scale chosen from the display (Miku Flick: 5x on a 2560x1440 1x display, was fixed 2x); Game Mode thread QoS and precise frame pacing (steady 33.3 ms in Metal HUD).
- Verified: 360 XCTest (22 skips) + 24 Swift Testing, 0 failures; GTA LCS windowed/maximised/full-screen fit confirmed by the user; Miku Flick full screen sharp.
- Not verified: Retina (2x) display, other 64-bit/32-bit titles, ProMotion pacing.
- 0.8.8 (34): Metal HUD is the only FPS meter. OpenGL ES games get a transparent Metal carrier layer presented once per game frame, so the HUD no longer disappears after a Metal UI screen (GTA LCS sign-in) and the runtime's separate FPS label is gone. Verified with GTA LCS: one HUD, 59.99 FPS, Game Mode On.

### 2026-11-13 — controllers in Unity games, iPhone 18 Pro profile (0.8.9)

- **Root cause of "UI Layout: Touch only" with a pad connected (Zenless Zone Zero, Genshin Impact, other Unity titles):** Unity's iOS player loads GameController with `[[NSBundle bundleWithPath:@"/System/Library/Frameworks/GameController.framework"] classNamed:@"GCController"]`. In a Catalyst process NSBundle describes the framework with the iOS flat layout (`…/GameController`) while the class comes from `…/Versions/A/GameController`, so `classNamed:` returned nil, Unity stored a nil class and its controller enumeration (`performSelector:@selector(controllers)`) always came back empty; no Gamepad reached the Input System. Found with lldb: Unity's `GCController` slot (`self+0x5a0`) was nil. PearRuntime now resolves `classNamed:` for bundles under /System when the class really comes from that framework (`PEAR_NO_BUNDLE_CLASS_FIX=1` disables). User confirmed: ZZZ offers Gamepad.
- The runtime no longer touches GameController at load time (it now waits for didFinishLaunching): the early query kept the Catalyst controller session from reporting a pad that was connected before the game started.
- A missed controller connect is replayed to every observer registered after the pad connected (per observer, not "seen by any query"), except an observer that enumerated in the same main-thread turn.
- **Default device profile:** iPhone 18 Pro `iPhone19,2` (board V63AP), iOS 27.2.1 `24B91034`, Darwin 27.2.0 (sources: The Apple Wiki, EveryiPhone, iClarified). IORegistry product name/board follow the model. Model-derived identifiers (identifierForVendor, synthetic serial/UUID) change with the model, by request.
- PearRuntime 0.9.1. Verified: 360 XCTest (22 skips) + 24 Swift Testing, 0 failures. Genshin not installed here; not verified.

### 2026-11-13 — legacy 64-bit iOS games: resolution, fit, window buttons (0.8.10)

- **Low internal resolution (Gutterball rendered 557x418 in a large window):** the legacy window fit read its logical size back from the UIWindow after applying the scale transform; UIKit reports bounds = frame / scale, so the size drifted each pass (1330 → 1728 → 2245, or downwards) and engines sized their render target from it. The logical size is now deterministic: the aspect the game launched with, fitted into the window's visible area at one UIKit point per window point, applied through UIKit (window + root view) so autoresizing follows. Gutterball: 986x740 windowed (1024x768 minus title bar), 1919x1440 full screen, 4:3 kept with letterboxing (a 16:9 surface left the 4:3 HUD in part of the frame with a black strip).
- **Title bar buttons not clickable in legacy games:** the direct legacy mouse→touch path swallowed every left click inside the full-size content view, title bar included. Mouse→touch and the legacy fit now use the window's content layout rect (below the title bar; whole view in full screen) via `PearWindowVisibleContentRect`. User confirmed minimize/zoom work.
- Restricting the legacy subtree-constraint skip to scene views crashed during window controller creation (`-[NSWindow _setFrameCommon:]`); the blanket skip stays.
- PearRuntime 0.9.2.

### 2026-11-13 — Cut the Rope giriş regresyonu / Minecraft arayüzü

- Kullanıcı Cut the Rope tıklamalarının ulaşmadığını, tanılama denemesinde ise yanlış konumda algılandığını bildirdi. Canlı günlükte hover/hareket olaylarının `allTouches` üzerinden native touch generation sayacını artırıp gerçek tıklama yedeğini iptal ettiği görüldü. Sayaç artık yalnız `UITouchPhaseBegan` ile ilerliyor.
- Native basma gelmeyen, kendi touchesBegan uygulaması olan GL/Metal render görünümlerinde gecikmeli yedek artık doğrudan responder teslimini kullanabiliyor. UIControl, UIScrollView ve gesture recognizer görünümleri bu otomatik yola alınmıyor. Virtual gamepad yolu değişmedi.
- GL window-space dönüşümü yeniden boyutlanmış pencereyi değil drawable'ın kendi mantıksal boyutunu referans alıyor. 768×1024 içeriğin 1360×998 pencerede orta/alt noktaları için geometri regresyon örnekleri eklendi. Görsel/oyun içi doğrulama bekleniyor.
- Minecraft ekran görüntüsünde pembe arayüz dokuları ve bozuk glifler var; sahne çiziliyor. Sistem Metal günlüğünde açık shader/texture hatası bulunmadı. Doku oluşturma başarısızlıklarını format/boyut/mipmap ile en fazla 32 kayıtla raporlayan isteğe bağlı tanılama eklendi. Minecraft için çözüm iddiası yok; kayıtlar/saves değiştirilmedi.
- Runtime derlemesi, bellek içi direct touch begin/move/end/cancel testi ve geometri testi geçti. Swift turu: **360 XCTest (22 skip) + 24 Swift Testing, 0 hata**. Değişiklikler runtime alt reposunda; commit/push/release yapılmadı.
- Son Cut the Rope denemesinde kullanıcı **“Evet, doğru yerde çalışıyor”** yanıtıyla PLAY/bölüm tıklamalarının doğru konuma gittiğini doğruladı. Sürükleme ve tüm oyunlar için başarı genellenmez.
- Güncel `build/PearSilicon.app` yeniden üretildi ve imzalandı; normal kurulumda kalıcılaştırmak için açık ana GUI'nin çıkışı bekleniyor. Minecraft tanılamalı açıldı; şu ana kadar nil texture allocation kaydı yok. Kullanıcının yeni görsel sonucu bekleniyor.

### 2026-11-13 — resize sonrası düzeltme devamı

- Kullanıcı yeniden boyutlandırma sonrasında giriş kaymasının sürdüğünü bildirdi. GL window-space dönüşümü artık mevcut drawable katmanının `convertPoint:fromLayer:` dönüşümünü kullanıyor; ilk renderbuffer boyutu/varsayılan merkez hesabına bağlı değil. Yalnız render görünümüne ait dokunmalara uygulanıyor.
- Son görüntüde oyun solda, sağ/alt alan beyaz kaldı. GL fit yolunun "artık pencereye sığıyor" dalı transformu kaldırıyor ve büyütmeyi atlıyordu; bu dal kaldırıldı. Büyütme/küçültmede aynı aspect-fit yolu korunuyor. Bu son değişikliğin kullanıcı doğrulaması bekleniyor.
- Güncel yerel uygulamanın ara sürümü /Applications'a kuruldu; önceki kopya `build/Backups/PearSilicon-before-resize-20261113-132609.app`. Son aspect-fit paketi yeniden derleniyor. Minecraft doku sorunu açık; cihaz modülünü kapatan tek seferlik karşılaştırma denemesi hazırlanıyor. Oyun verisi değiştirilmedi.

### 2026-11-13 — GL ve Metal arka uçlarının ayrılması

- Kullanıcı cihaz kimliği kapalı Minecraft denemesinde doku/glif bozulmasının sürdüğünü ve bulanıklık olduğunu bildirdi; bu deneme çözüm sayılmıyor, kalıcı tercih yapılmadı.
- PearRuntime kaynakları `modules/graphics-gl/GLShim.mm` ve `modules/graphics-metal/MetalLayerShim.mm` olarak ayrıldı. Ortak `graphics` ekran/pencere geometrisini korur. Üst `graphics` seçimi iki çocuğu içerir; üstü kapatmak ikisini kapatır. `graphics-gl`/`graphics-metal` tek başına seçilebilir; açıkça kapatma önceliklidir. Seçim yalnız launch ortamından bir kez okunur; oyun adına/çip adına göre tahmin yapılmaz.
- Altı ayrı süreçli modül politika testi geçti (`scripts/graphics-module-smoke.cpp`); runtime derlendi. Bu mimari ayrım Minecraft'ın pembe dokularını çözdüğü anlamına gelmez.
- Cut the Rope için son büyütme/küçültme aspect-fit ve canlı katman input dönüşümü denemesi hazırlanıyor. Minecraft için yalnız Metal + yerel ekran davranışı karşılaştırması sonraki tanılama adımı; mevcut oyun süreci izinsiz kapatılmıyor.
- Pencereli Cut the Rope görüntü/tıklama doğru; kullanıcı tam ekranda tıklamanın gitmediğini ve iç çözünürlüğün düşük kaldığını bildirdi. Günlükte pencere 1568×1252 → 3325×1871 iken fit ölçeği 1.223'te kalıyordu: UIKit eski transform üzerinden view bounds'u büyütüyor, GL fit bunu yeni mantıksal oyun alanı sanıyordu. Mantıksal boyut artık başarılı renderbuffer tahsisinin piksel boyutu / contentsScale değerinden alınır; pencere autoresizing'i tahsis olmadığı sürece bu alanı değiştiremez. Son paket derlendi; tam ekran doğrulaması bekleniyor.
- Bu düzeltme 768×1024 framebuffer'ı daha yüksek çözünürlükte yeniden çizilmiş yapmaz; engine renderbuffer/viewport'u birlikte yeniden kurmadan yüksek iç çözünürlük garantisi verilmez. Keskinlik ve giriş ayrı doğrulanmalı.
- Minecraft, güncel split runtime ile `graphics-gl` ve `UIScreen` shim'i kapalı, cihaz modülü açık tek seferlik karşılaştırmayla başlatıldı (`/tmp/pear-minecraft-metal-native-screen.log`). Günlükte yalnız `graphics-metal` backend'i var; EAGL/UIScreen hook kurulum satırı yok. Kullanıcı sonucu bekleniyor. Bu ayarlar kalıcı yapılmadı.
- Son Cut the Rope kullanıcı testinde tıklamalar düzeldi; kalan sorun görüntünün yukarı kayması/altta boşluk. GL fit artık pencere rect'ini doğrudan parent katmana dönüştürüp anchorPoint'e göre yerleştirir; eski parent bounds merkezine güvenmez. Bounds/position/transform animasyonsuz tek CATransaction içinde uygulanır; UIKit transformu sıfırlarsa cache erken dönüşü bunu kaçırmaz. Son görsel doğrulama bekleniyor.
- Minecraft UI materyalleri + Mojangles fontu orijinal IPA ile karşılaştırıldı: 7 dosya, 0 fark. Metal shader library/pipeline oluşturma başarısızlıkları için opt-in ve 32 kayıtla sınırlı hata tanılaması eklendi; shader/doku içeriği değiştirilmez.
- Kullanıcı üç uygulamadan çıktı; paket `/Applications/PearSilicon.app` içine kuruldu, imzası doğrulandı. Yedek `build/Backups/PearSilicon-before-graphics-20261113-134105.app`. Cut the Rope ve Minecraft runtime yenilemeleri başlatıldı. Minecraft'ın başarısız cihaz/ekran kapatma denemeleri kalıcı tercihe yazılmadı; sonraki başlatma normal profil + tanılama olacak.
- Son kurulu pakette kullanıcı Cut the Rope için **“Yerleşim ve tıklamalar düzgün”** yanıtıyla pencere büyütme/küçültme/tam ekran yerleşimi ve tıklamaları doğruladı. Günlükte OpenGLView bounds 768×1024 sabit; frame görünür pencere içinde ortalı, tam ekran fit ölçeği gerçek boyuta göre değişiyor. İç çözünürlük artışı bu doğrulamaya dahil değil.
- Minecraft normal ekran/cihaz profiliyle ve library/pipeline tanılamasıyla yeniden açık. Şu ana kadar texture/library/pipeline başarısızlığı kaydı yok; pembe UI/glif sorununun nedeni halen belirsiz. Sonraki inceleme Metal API/shader validation ile kaynak bağlamalarını doğrulamak.

### 2026-11-13 — kullanıcı isteğiyle ANGLE yönüne geçiş

- Kullanıcı sistem OpenGLES yerine ANGLE tabanlı bağımsız GLES yolu istedi. `denizomer10/angle` zaten Google ANGLE fork'u (ADMIN erişimi doğrulandı); yeni mükerrer repo oluşturulmadı. PearSilicon/PearRuntime'da `codex/angle-metal-bridge`, ANGLE checkout'unda `codex/pearruntime-metal` dalı açıldı. Önceki değişiklikler korundu.
- Fork, PearRuntime'a `third_party/angle` alt modülü olarak **686adbb2a39854ab687da009e534f6842a85f453** revizyonunda pinlendi. LICENSE korundu; Chromium build bağımlılıkları henüz indirilmedi. Kaynak checkout'u yaklaşık 109 MB.
- PearRuntime `graphics-gl` modülüne orijinal ANGLE yükleyici eklendi: Metal EGL display, proc resolution, eksik kütüphaneden toparlanma ve süreç içinde değiştirilemeyen backend seçimi. EAGL yönlendirmesi henüz etkin değil; sistem GL çağrıları ile ANGLE nesneleri karıştırılmıyor.
- **Gerçek Catalyst/Metal testi geçti:** EGL 1.5, renderer `ANGLE Metal Renderer: Apple M1`, 16×16 pbuffer RGBA readback **64,128,191,255**. Yükleyici hata/tekrar başlatma testleri geçti. Runtime derlendi ve ANGLE API export'ları dylib'de doğrulandı.
- Önemli test sınırı: bu ilk test, mevcut 32-bit motor paketindeki macOS ANGLE dylib'lerini 64-bit Catalyst sürecinden yükledi. Pinlenen fork'un yeni derlemesi değildir; binary kaynak revizyonu doğrulanmış gibi gösterilmemeli. Oyunların ANGLE üzerinden çizildiği iddia edilmemeli.
- ABI envanteri: Cut the Rope ana binary'sinde 50 GL import + EAGLContext; Minecraft'ta 88 + EAGLContext. Bu, aktif renderer'ı tek başına kanıtlamaz. Rapor `build/diagnostics/angle-import-audit.json`.
- Tekrarlanabilir test: `bash scripts/test-angle-backend.sh`; sınırlar ve sonraki EAGL/context/FBO/present/import yönlendirme adımları `docs/ANGLE_INTEGRATION.md`. Native Metal girdisinin ANGLE tarafından çevrildiği iddia edilmiyor; bu ayrı adaptör gerektirir.
- Yeni ANGLE çalışması kaynak/deneme aşamasında; oyunlara kurulmadı, commit/push/release yapılmadı.

### 2026-11-13 — ANGLE context/sunum çekirdeği ve gerçek kaynak derlemesi

- Orijinal `PearANGLEContext` eklendi: GLES 2/3 sharegroup nesneleri, pthread tabanlı current-context sahipliği, thread değiştirme, açık piksel boyutlu pbuffer tahsisi ve başarısız resize durumunda eski drawable'ın korunması. Yanlış thread'den kullanım/resize reddedilir.
- RGBA8 color attachment 0 framebuffer'ı EGL drawable'a kopyalanıp sunulabilir. Read/draw FBO bağlamaları, viewport, scissor, color mask ve çağıranın mevcut GL hata durumu korunur. ES2 ANGLE blit ölçekleme desteklemediği için farklı piksel boyutları erken reddedilir; ES3 core blit kullanır.
- Eski staged ANGLE'da thread current-context bırakmadan kapanınca tekrar bağlama `EGL_BAD_ACCESS 0x3002` veriyordu. Fork'ta Apple cleanup etkinleştirildi ve callback sırasında temizlenmiş thread TLS slotu geçici olarak geri kuruldu. Kaynak fix **9e214cf2b9154b2e4d08d44d9d1bdd0255e623ca**, `denizomer10/angle` `codex/pearruntime-metal` dalına push edildi.
- ANGLE Metal-only **kaynaktan derlendi**: GN/DEPS-pinned Clang 24, yerel Xcode macOS 27.2 SDK. Vulkan/Dawn/OpenCL/SwiftShader/test trace bağımlılıkları bu profilin dışında. EAGL/frontend hâlâ oyuna yönlendirilmedi.
- Kaynak binary ile gerçek Catalyst testleri geçti: Metal EGL pbuffer RGBA readback, yükleyici, paylaşımın ilk context silindikten sonra sürmesi, resize/readback, incomplete-FBO rollback, thread sahipliği ve **16 thread-exit/rebind döngüsü**. GLES2/3 GLSL shader compile/link + Metal üçgen çizimi readback **255,255,0,255** geçti.
- Tekrarlanabilir komut: `bash scripts/build-angle-metal.sh [--sync]`; test: `bash scripts/test-angle-backend.sh`. `runtime/third_party/angle/out/PearMetal/pearruntime-build.json` kaynak commit, temiz/diff durumu, compiler/SDK, GN args, test log ve dylib hash'lerini kaydeder. `gameRoutingValidated=false`.
- PearRuntime context çekirdeği + önceki graphics split/fixler **1386314**, `denizomer10/PearRuntime` `codex/angle-metal-bridge` dalına push edildi. Henüz yeni release/tag, 64-bit oyunlara ANGLE paketleme veya varsayılan backend değişimi yok. GLES1 sunumu, native-window EGL yüzeyi, EAGL renderbuffer/import yönlendirmesi ve MSAA/renk formatları sonraki işler.

### ANGLE native katman yüzeyi — 2026-11-13

- `PearANGLEContext` artık EGL window surface ile CALayer/CAMetalLayer bağlayabiliyor. Piksel boyutu EGL'den doğrulanıyor; bounds/backing scale değişince eski geometriyle sunum reddediliyor. Renderbuffer ve input geometrisinin birlikte yenilenmesi sonraki EAGL adaptörünün sorumluluğu; oyunlarda henüz etkin değil.
- Kaynak ANGLE testinde konumu sıfır olmayan host katmanı için alt Metal katmanı yanlış yerdeydi: `frame = host.frame`. Önce başarısız testle doğrulandı; fork'ta `frame = host.bounds` düzeltmesi `f405241` olarak kaydedildi. Apple sistem uygulama kodu kopyalanmadı.
- Kendi test sürecinde, görünür pencere/odak/otomatik giriş olmadan gerçek GPU clear/readback/swap; 1×/2×/1,5× yeniden bağlama; eski geometriyi reddetme; aynı host'u ikinci context'e bağlamayı reddedip eski pbuffer'ı koruma ve detach temizliği geçti. GLES2/3 shader, GL durumunu koruma, paylaşım ve 16 thread-exit testi de geçti. Tam PearRuntime Catalyst derlemesi başarılı.
- Kaynak/ikili manifestine test ve köprü kaynaklarının hash'leri eklendi; yeni derleme eski başarı manifestini geçersiz kılıyor.
- Test kaydı: `/tmp/pear-angle-native-final-validation.log`; runtime derlemesi: `/tmp/pear-angle-native-runtime-build.log`. Minecraft/oyun EAGL yönlendirmesi, tam ekran/input transaction, GLES1 sunumu ve dağıtım/lisans paketlemesi tamamlanmış sayılmaz. Kurulu oyunlar yeni ANGLE çekirdeğine geçirilmedi; release/tag yok.

### ANGLE renderbuffer / EAGL selector adaptörü — 2026-11-13

- Özgün `PearEAGLContext`/`PearEAGLSharegroup`, public context/sharegroup/current-context, drawable tahsisi ve anlık sunum selector'larını ANGLE çekirdeğine bağlıyor. Sistem EAGL sınıfıyla aynı ad altında kaydedilmiyor; oyun yönlendirmesi henüz yok. Apple public sabit değerleri ayrı, salt okunur export probuyla doğrulandı; Apple uygulama kodu eklenmedi.
- `ANGLEDrawable.mm`, bound renderbuffer'ı gerçek EGL piksel boyutunda RGBA8/single-sample tahsis ediyor; saklanan özel FBO üzerinden sunuyor. Sunum sonrasında oyun renderbuffer'ını özel FBO'dan ayırıyor. Retained backing kaynak piksel içeriğini koruyor; nil drawable storage'ı bırakıyor. RGB565/sRGB, MSAA, zamanlanmış sunum ve GLES1 sunumu henüz uygulanmadı.
- Başarılı tahsis bounds/piksel/scale/generation geometrisini birlikte yayımlıyor. GL context'i olmayan input thread'inden okuma/eşleme doğrulandı. Resize sonrası eski nesil ve değişmiş katman reddediliyor; bu API henüz UIKit olaylarına bağlanmış değil. Import sarmalayıcıları GL silme/aynı isimle yeniden oluşturmayı ayrıca takip etmeli.
- Gerçek GLES2/3 testleri: tahsis/sunum, retained mavi piksel okuma, ayrı read/draw FBO ve viewport/scissor/renderbuffer durumunu koruma, engine GL hatasını tüketmeme, resize nesli, input thread'inden koordinat dönüşümü geçti. Selector testi RGBA8 pembe/magenta piksel okuma, sharegroup sürüm kontrolü, thread sahipliği ve 8 örtük çıkışta wrapper serbest bırakmayı geçti. Önceki context/shader/native surface testleri de geçti.
- Kayıtlar: `/tmp/pear-angle-eagl-final-validation.log`, `/tmp/pear-angle-eagl-final-build.log`. Kurulu oyunlar ve kayıtlar değiştirilmedi; Minecraft/oyun tam ekran dokunması için çözüm iddiası yok. Sonraki gerekli bağlantı: linked GL importları + dinamik fonksiyon/sınıf aramalarının birlikte yönlendirilmesi, oyun resize/input işlemi, paketleme ve canlı oyun doğrulaması.

### ANGLE GL importları / dinamik çağrılar ve canlı oyun doğrulaması — 2026-11-13

- `ANGLEGameRouting.mm`: `PEAR_GRAPHICS_BACKEND=angle` + `PEAR_ANGLE_LIB_DIR` ile açık seçim. Yalnız ana app ve gömülü image import slotları güncelleniyor; sistem image'ları/komut baytları değiştirilmiyor. Classic bind/lazy/weak tabloları, geri giden unsigned offsetler ve signed 64-bit addend'ler işlendi. GL fonksiyonları, EAGL class/metaclass, EAGL/egl proc lookup, dlsym, CFBundle function lookup ve dinamik sınıf aramaları aynı ANGLE yoluna bağlı. Renderbuffer silme metadata'yı geçersiz kılıyor. arm64e/chained/threaded formatlar desteklenmiyor; başarısızlıkta karışık native GL fallback yok.
- GL geometry hook artık ANGLE context'i ve ANGLE query fonksiyonlarını kullanıyor; ilk drawable tahsisinden önce kuruluyor. `graphics-gl` kapalıysa ANGLE açıkça reddediliyor. Launcher bir oyunun backend/dylib tercihini diğerine taşımıyor.
- Ayrı imzalı `.angleprobe` kopyalar ve ayrı yeni home dizinleri hazırlandı. Normal kurulumlar ve açık orijinal Minecraft süreci değiştirilmedi. Cut the Rope 57, Minecraft 92 import yönlendirdi. Cut gerçek ANGLE GLES2/Metal çizim + sunum yolunda; Minecraft örneklemesinde native Metal çizim var ve EAGL context açılışı yok. Minecraft Metal'i ANGLE'a çevrilmiş sayılmaz.
- İlk Cut testi görünür yükleme ekranında kaldı: geçici UIKit bounds değişimi geçerli renderbuffer kaydını kalıcı siliyordu. Artık yalnız o kare reddediliyor, geometri eskiye döndüğünde storage kaybolmadan sunum devam ediyor. GPU regresyon testi yeniden tahsis olmadan değiştir/geri dön durumunu geçti.
- Cut'ta sentetik `PearLegacyTouch` kendi override'ı nedeniyle UITouch taban sınıfı dönüşümünü atlıyordu. Native/sentetik current + previous koordinatlar ortak GL dönüşümüne alındı; view-local cevap korunuyor. Basma/sürükleme geçmişi ve subclass mapping bellek içi testte doğrulandı.
- UIScreen worker cache'i render thread'inde eski boyutta sonsuza kadar kalabiliyordu; ilk cache dolmadan worker UIKit ağacını da okuyabiliyordu. Kilitli cache/override, ana thread producer, coalesced refresh ve resize/backing bildirimi eklendi. 100 worker okumasının tek ana thread güncellemesiyle yeni boyuta geçmesi test edildi.
- Minecraft testinde zorunlu legacy responder ayarı kaldırıldı, adaptive fallback ve native pointer lock izni açıldı. Kullanıcı son testte Cut küçük/tam ekran + PLAY/ip kesme için **“İkisi de düzgün”**, Minecraft için **“Yakalama, görüntü ve giriş düzgün”** doğrulaması verdi. Bu doğrulama yeni test profillerine aittir; eski Minecraft kaynak/ayar cache'i veya her dünya için genellenmez.
- Otomatik kontroller: gerçek Mach-O import slotları + dinamik proc/class + Metal piksel okuma/sunum; backend kapalı native korunumu; GL modülü kapalı reddetme; mevcut GLES2/3 context/shader/storage testleri; native/sentetik dokunma ve worker screen cache testleri; 7 AppLauncherEnvironmentTests, 0 hata. Runtime Catalyst derlemesi geçti. Test komutları `docs/ANGLE_INTEGRATION.md` içinde.
- Kullanıcı test sonuçları ve çalıştırılan runtime SHA'ları yerel `build/diagnostics/angle-game-validation.json` dosyasına yazıldı. Hazırlama/başlatma yardımcıları depoya eklendi; sonraki kopyalarda mutlak dependency/rpath'ler de yalnız kopyada yenileniyor. Kurulu uygulamalar otomatik ANGLE'a geçirilmedi; release/tag ve genel dağıtım lisans paketlemesi yapılmadı.

## Sonraki ajana devir — tamamen ANGLE (2026-11-13)

### Kullanıcının son hedefi ve durma noktası

- Son talimat: **“tamamen ANGLE kullanmalı, sistem EAGL'yi sileceğiz.”** Ardından kullanıcı token limiti nedeniyle kalan işi bu dosyaya kaydetmemi, başka ajanla devam edeceğini söyledi. Bu aşamada yeni geliştirme durduruldu; aşağıdaki exclusive değişiklikler tamamlanmış/kararlı sayılmıyor.
- Kaldırılacak olan **PearRuntime'ın sistem OpenGLES/EAGL renderer yolu ve oyunların bu framework'e doğrudan bağımlılığı**. macOS sistem dosyaları silinmeyecek. Native Metal çağrıları ANGLE'ın girdisi değildir; Minecraft'ın native Metal yolunu ANGLE'a çevirdiğimiz iddia edilmeyecek.
- Modüler tasarım ve clean-room ilkesi korunacak: bridge kaynakları özgün; ANGLE lisanslı üçüncü taraf. Apple OS uygulama kodu kopyalanmadı; public API/SDK arayüzleri kullanılıyor.
- Son çalışan, GitHub'a gönderilmiş checkpoint: PearSilicon **`fd11163`**, PearRuntime **`26096cc`**, ANGLE fork **`f405241`**. Root/runtime dalı `codex/angle-metal-bridge`; ANGLE dalı `codex/pearruntime-metal`. Yeni exclusive aşama bu checkpoint'in üzerinde **WIP** olarak saklanıyor; HEAD'leri `git log -1`, `git -C runtime log -1`, `git -C runtime/third_party/angle log -1` ile kontrol et.

### Gerçek oyunlarda zaten doğrulanan, bozulmaması gereken kısım

- Önceki opt-in import-slot yolu ile Cut the Rope: 57 GL/EAGL import ANGLE'a bağlandı, gerçek ANGLE GLES2→Metal çizim/sunum görüldü. Yükleme ekranının donması, geçici resize'da storage metadata'sının silinmesiydi; düzeldi.
- `PearLegacyTouch` subclass'ı UITouch taban sınıfı dönüşümünü atlıyordu. Native/sentetik **current ve previous** koordinatlar `PearGLMapTouchPoint` üzerinden aynı dönüşüme alındı. Kullanıcı küçük pencere/tam ekran, PLAY/ip kesme için **“İkisi de düzgün”** doğruladı.
- Minecraft test kopyası: 92 import yönlendirildi ama örnekleme **native Metal renderer** gösteriyor, EAGL context açılışı gözlenmedi. Zorunlu legacy responder input kaldırıldı, native pointer lock izni açıldı; UIScreen worker cache'i düzeltildi. Kullanıcı **“Yakalama, görüntü ve giriş düzgün”** dedi. Yeni/ayrı test home'u kullanıldı; eski Minecraft kaynak/ayar cache'inin kök nedeni çözülmüş sayılmaz.
- Çalışan test kopyaları: `build/angle-game-tests/`, manifest `games.json`, runtime günlükleri `0-runtime.log` / `1-runtime.log`, PID dosyaları `0.pid` / `1.pid`. Son bilinen test PID'leri Cut `63126`, Minecraft `63128`; **yeniden kontrol et, PID'ye körlemesine işlem yapma**. Orijinal Minecraft daha önce PID `46857` ile açıktı ve değiştirilmedi. Açık kullanıcı oyunlarını kapatma; çalışan test kopyalarını da bu devirde yeniden başlatmadım.
- Manuel sonuçlar ve denenmiş runtime SHA'ları: `build/diagnostics/angle-game-validation.json`. Bu kopyalar hâlâ önceki macOS-target ANGLE (`out/PearMetal`) / import-slot sürümünü kullanıyor; yeni exclusive paketleme/Catalyst sürümü bu oyunlarda henüz denenmedi.

### Yeni exclusive aşamada yazılanlar

**PearRuntime:**

- `generate-angle-forwarders.py`: pinlenmiş Khronos GLES registry + ANGLE export listesinden **728 typed GLES forwarder** üretir. Üretilen `.mm/.o` build çıktısıdır, kaynak devasa generated dosyası commit edilmez.
- `bridge/EAGLExports.mm`: özgün EAGL public sabitleri, `EAGLGetVersion`, strict proc lookup. Sabitlerde `extern` eklendi; yeni tam derleme ile exportları tekrar kontrol et.
- `bridge/context-aliases.sh`: runtime'ın özgün `PearEAGLContext`/sharegroup class/metaclass sembollerine public EAGL ABI alias'ları verir. ObjC kayıt adları özgün kalır; native sınıf implementation'ı kopyalanmıyor.
- `build-angle-bridge.sh`: **`libPearOpenGLES.dylib`** üretir; runtime'ı re-export eder. `build.sh` alias flag'lerini ve bridge derlemesini çağırıyor. **ANGLE dylib'lerini `build/PearANGLE` içine stage etme henüz yazılmadı.**
- `GLShim.mm`: `OpenGLESHandle`, native `dlsym` fallback ve native EAGLContext seçimi kaldırıldı. GL query/proc yalnız ANGLE. Routing açık değilse GL hook kurulmaz.
- `ANGLEGameRouting.mm`: bridge image'ı kendi runtime artifact'i olarak atlar. Bind stream dylib ordinal'ını takip eder; import zaten `libPearOpenGLES`'ten geliyorsa typed forwarder'ı atlamaz, slotu yerinde bırakır. Dinamik lookup'lar hâlâ aynı ANGLE domain'ine bağlanır.
- `dlopen` app importu da route edilir: `OpenGLES.framework` adları yüklü kendi bridge'imize yönlendirilir, native OS framework'e fallback yapılmaz. Alakasız dlopen/dlsym için musttail caller semantiğini korur.
- `PEAR_GRAPHICS_BACKEND=system` artık açıkça reddedilir. Bridge yüklenmişse `PEAR_GRAPHICS_BACKEND` olmadan da auto ANGLE etkinleşir. Varsayılan libs yolu flat iOS app için `Frameworks/PearANGLE`; dev override `PEAR_ANGLE_LIB_DIR` kalır.

**Önemli bootstrap eksiği:** yalnız dinamik GL kullanan / başlangıçta bridge LC_LOAD'u olmayan compatibility app'lerde constructor henüz yalnız yüklü bridge'i algılıyor. Hazırlanmış sibling `libPearOpenGLES.dylib` dosyasını algılayarak otomatik etkinleştirme veya launcher'ın güvenilir paket yolunu seçmesi eklenmeli. `PearBridgePath` de bu durumda local artifact'e ayarlanmalı. Sistem fallback geri getirilmemeli. `graphics-gl` bilinçli kapalı ve GL gerektirmeyen core-only probe'ları gereksiz yere öldürmemeye dikkat et.

**Root/Swift paketleme (WIP):**

- `PackageInstaller.installANGLE(...)` eklendi: her compatibility pakete `libPearOpenGLES.dylib`, `PearANGLE/libEGL.dylib`, `PearANGLE/libGLESv2.dylib` zorunlu kopyalar; tüm app Mach-O'larında sistem OpenGLES dependency'lerini final target bridge yoluna çevirir. Staging mutlak yolu yazılmamalı.
- Compatibility invariant'ları yeni bileşenleri ve doğrudan sistem OpenGLES dependency'sinin kalmamasını denetliyor. Native container cleanup yeni artifact'leri de kaldırıyor. Statik OpenGLES/bridge dependency'si olan oyunu no-runtime `nativeContainer` kipine geçirmek açıkça reddediliyor; bu kiple gizlice native EAGL fallback yok.
- `RuntimeRevision.componentNames` yeni bridge + `PearANGLE` içeriyor; source'ta bu zorunlu bileşenler varsa installed'da eksikleri current sayılmıyor.
- `PreparationModeTests` / `InstallerIntegrityTests` fixture'larına yeni Catalyst stand-in artifact'leri eklendi. Gerçek codesign testi yeni stand-in dylib'leri gerçek Catalyst hedefinde derliyor.
- `scripts/angle-catalyst-args.gn` ve `scripts/test-angle-exclusive.sh` eklendi; eski routing smoke, strict sistem backend reddetmesine uyarlandı.

### ANGLE fork'un yeni Catalyst port düzeltmeleri

- Kaynak doğrudan **`arm64-apple-ios15.0-macabi`** ile derlendi; Mach-O platform bilgisi sonradan taklit edilmiyor.
- `BUILD.gn`: Catalyst'te host modelini okuyan mevcut platform helper için public IOKit link dependency eklendi.
- `mtl_utils.mm`: yalnız macOS'ta derlenen IOKit vendor helper'ı Catalyst'te çağrılmıyor; mevcut public Metal device-name vendor fallback'i kullanılıyor.
- `gni/angle.gni`: Catalyst için framework yerine normal `.dylib` üretimi.
- `system_utils_ios.cpp`, `system_utils.cpp`, `system_utils_posix.cpp`: Catalyst `.dylib` uzantısı ve module-relative yükleme; gerçek iOS'ta framework/bundle kuralları korunuyor. Bu, `PearANGLE/` içindeki iki dylib'in birlikte taşınabilmesini sağlıyor.
- İlk framework→dylib geçişinde `out/PearCatalyst/obj/libEGL` / `obj/libGLESv2` eski output **dosyaları** yeni object dizinleriyle çakıştı; yalnız bu iki eski build dosyası silinip derleme tamamlandı. Aynı eski out ile yeniden framework tipini değiştirirsen bu çakışmaya dikkat et.
- Çıktılar: `runtime/third_party/angle/out/PearCatalyst/libEGL.dylib` + `libGLESv2.dylib`, platform **MACCATALYST**, minOS 15.0. Eski `out/PearMetal` dosyaları çalışan testler için bırakıldı.

### Son test durumu — açık hata var

- **GEÇTİ:** `/tmp/pear-angle-catalyst-gpu-tests.log`: gerçek Catalyst ANGLE ile pbuffer piksel okuma, loader, sharing, GLES2/3 sunum/durum, 16 thread-exit, GLSL shader, native katman, renderbuffer/input generation, EAGL selector + 8 TLS cycle testleri.
- **GEÇTİ (önceki exclusive snapshot):** `/tmp/pear-exclusive-angle-first-test.log`, `/tmp/pear-exclusive-angle-automatic-test.log`: kendi GLES/EAGL bridge'ine gerçek linkli test; Metal piksel okuma/sunum ve **test sürecinde hiç sistem OpenGLES image'ı yüklenmediği** kontrolü. Sonradan eklenen ikinci auto-backend koşusu ve legacy-name `dlopen` redirect assertion'ı henüz tekrar çalıştırılmadı; ayrıca testi yeni Catalyst libs ile çalıştır.
- **AÇIK HATA:** `/tmp/pear-exclusive-installer-tests.log`: **45 test, 1 failure**. `PreparationModeTests.testRuntimeRefreshRunsOffTheMainThread` satır ~366: ikinci refresh `false` olmalı, `true` geliyor (**“a refreshed app must be reported as current”**). Yeni artifact/normalizasyon/contentManifest karşılaştırmasını incele; nedeni varsayılıp test gevşetilmedi. Diğer installer tests ve RuntimeRevision testi geçti.
- Son full runtime build `/tmp/pear-exclusive-runtime-build.log` bridge'i üretti, ancak **daha sonraki strict bootstrap/GLShim değişiklikleri ve extern sabit düzeltmelerinden önce** idi. Güncel kaynakla yeniden derle. Şu an `runtime/build/PearANGLE` gerçek Catalyst binary staging'i yok; installer'ı normal oyunlara uygulama.
- Önceki çalışan checkpoint'in testleri: tüm GPU/import/input/screen smoke + 7 AppLauncherEnvironmentTests geçti. Yeni exclusive packaging değişikliklerinden sonra **full Swift suite henüz çalışmadı**.
- İlgili diğer loglar: `/tmp/pear-angle-catalyst-flat-build.log` (başarılı), `/tmp/pear-angle-catalyst-dylib-build.log` (eski output çakışması, superseded), `/tmp/pear-angle-catalyst-final-build.log` (önceki IOKit link hatası, superseded).

### Öncelikli kalan adımlar

1. **Önce installer tekrar-refresh hatasını çöz.** 45 seçili testi tekrar geçir; eksik artifact ve rollback invariant'larını gevşetme. Runtime kodunun yeniden imzalanmasının gerçek code change sayılmaması ilkesi korunmalı.
2. `scripts/build-angle-metal.sh` hâlâ varsayılan olarak **macOS `out/PearMetal`** derliyor. Catalyst hedefini/script seçimini entegre et; `angle-catalyst-args.gn` + `out/PearCatalyst` ana compatibility çıktısı olacak. Test varsayılanları, helper/probe launcher ve provenance manifestindeki platform/yollar buna uyarlanmalı. Exclusive testi build validation zincirine ekle.
3. Gerçek Catalyst ANGLE çıktısını **`runtime/build/PearANGLE/{libEGL.dylib,libGLESv2.dylib}`** içine stage eden adımı ekle; gereken üçüncü taraf lisans/notice dosyalarını koru. `runtime/build.sh` / parent build pipeline bunu üretmeli veya açık eksik-artifact hatası vermeli. **Mac dylib'inin platformunu patchleyerek admission'ı atlama.**
4. `scripts/build-app.sh`, `.app/Contents/Resources` içine yeni **`libPearOpenGLES.dylib` + `PearANGLE/`** bileşenlerini de paketlemeli. Yeni runtime/source yollarının seçildiğini kontrol et; eski `/Applications` kaynaklarına sessizce geri düşme.
5. Yukarıdaki bootstrap eksiğini kapat: fresh prepared dynamic-only GL + environment-injection kipi de auto ANGLE kullanmalı. Explicit sistem backend/fallback yok; no-runtime nativeContainer'ın anlamı korunmalı, GL gerekiyorsa açık ret.
6. Güncel runtime'ı ve bridge'i derle; alias/sabit/GLES exportlarını `nm`, app dependency'lerini `otool -L`, platformu `vtool` ile doğrula. `bash scripts/test-angle-exclusive.sh <.../out/PearCatalyst>` dahil bütün ilgili smoke'ları geçir. Exclusive testte gerçek typed export çağrıları **GL slotlarına doğrudan raw-pointer patch uygulanmadan** deneniyor; bu kontrol korunmalı.
7. Yeni, **ayrı** exclusive oyun kopyalarında (eski doğrulanan test süreçlerine/normal oyunlara dokunmadan veya kullanıcının çıkışını bekleyerek) PackageInstaller akışını test et. Main + embedded Mach-O'larda sistem OpenGLES load command kalmamalı. Typed bridge → Catalyst ANGLE → Metal yolunu, Cut dokunma/drag/small/fullscreen ve Minecraft'ın native Metal input/scale/capture profilini yeniden doğrula. Minecraft Metal çağrılarını ANGLE'a çevirdik deme.
8. Full Swift testleri, final runtime build + API/graphics testleri; sonra fork→runtime→root commit/submodule pointer/push. Şu anki exclusive değişiklikler **WIP**; release/tag yayınlama, tüm oyunlar/M5/M6 için doğrulama iddiası yapma. Yalnız bu Apple M1 test makinesi var. Chained/threaded fixups, arm64e, GLES1 sunumu, RGB565/sRGB/MSAA/zamanlanmış sunum hâlâ desteklenmiyor.

### Çalışma sınırları / araçlar

- CWD `/Users/mac/PearSilicon`; Türkçe iletişim. Ekran görüntüsü/desktop otomasyonu/odak çalma/otomatik tıklama yok. Arka planda CLI/NSWorkspace launch, salt okunur process/window metadata ve kendi headless GPU/bellek içi testleri kullanıldı.
- Asıl oyun verileri korunacak. Test kopyalarının home'ları `build/angle-game-tests/*.home`, normal kayıtlar ayrı. Doğrulanan açık testleri bu exclusive devirde overwrite etme.
- `gh` ve `ninja`: `/opt/homebrew/bin/`; depot_tools `build/angle-tools/depot_tools`; Clang 24 ANGLE DEPS içinde. Full disk erişimi var; approval policy never, `sandbox_permissions` verme.
- Yeni task/agent spawn edilmedi. Kullanıcı başka ajanla devam edeceğini söyledi; bu dosyadaki devirden sonra geliştirmeye devam etme.

### Devam — Catalyst ANGLE paketleme, tembel routing, ilk gerçek installer testi (2026-11-13)

Bu oturumda devir listesindeki 1–6. adımlar tamamlandı; 7. adımda açık hata bulundu.

- **Installer tekrar-yenileme hatası çözüldü (1):** `RuntimeRevision.contentManifest` dizin bileşenlerinde (PearANGLE, MarketplaceKit.framework) sabit ön ek uzunluğu kesiyordu; numaralandırıcı `/private/var` döndürünce yollar `meworks/PearANGLE/…` gibi bozuluyor, güncel uygulama her kontrolde yeniden işleniyordu. Göreli yollar artık `enumerator(atPath:)`'ten. Regresyon testi `RuntimeRevisionTests.testDirectoryComponentsMatchUnderSymlinkedTemporaryPath` (düzeltmesiz başarısız, düzeltmeyle geçiyor). Not: XCTest'in "caught error … .pear-injection" mesajı yanıltıcıydı (son yakalanan atışı gösteriyor); gerçek sızıntı lldb `swift_willThrow` ile bulundu.
- **Catalyst varsayılan (2):** `build-angle-metal.sh` varsayılanı `PEAR_ANGLE_TARGET=catalyst` → `out/PearCatalyst` (`angle-catalyst-args.gn`); `macos` → `out/PearMetal`. Test betikleri Catalyst'e döndü; exclusive test derleme doğrulamasına eklendi; manifest platformu yazıyor.
- **Staging (3):** `runtime/build.sh` Catalyst `libEGL/libGLESv2`'yi platform kontrolüyle (`vtool` MACCATALYST, yamalama yok) ve `LICENSE.ANGLE` ile `build/PearANGLE`'a koyuyor, id `@rpath/PearANGLE/…`; eksikse duruyor.
- **Paketleme (4):** `build-app.sh` `libPearOpenGLES.dylib` + `PearANGLE/`'ı Resources'a koyuyor, eksikse duruyor; `publish-release.sh` eksik/Catalyst olmayan bileşenle yayını reddediyor.
- **Bootstrap eksiği kapandı (5):** köprü yüklü değilse runtime yanındaki `libPearOpenGLES.dylib`'i bulup routing'i **tembel** kuruyor: `dlopen("OpenGLES")` köprüye gidiyor, ANGLE ilk GL kullanımında başlıyor (Metal oyunlar yük taşımıyor), bu kipte `graphics-gl` kapalıysa süreç öldürülmüyor; başlatma hatasında sistem GL'ye düşmeden `_exit(78)`. ANGLE önce runtime'ın yanındaki `PearANGLE`'dan aranıyor. Yeni senaryo `scripts/angle-dynamic-smoke.mm` (GL'ye bağlanmayan, sistem yolunu dlopen eden istemci) `test-angle-exclusive.sh`'de: köprüye yönlendi, ANGLE tembel başladı, sistem OpenGLES imajı yüklenmedi.
- **Taşıma (relocation):** ANGLE öncesi kurulmuş uygulama taşınabiliyor (ANGLE bir sonraki runtime yenilemesinde gelir, parmak izi değiştiği için yenileme kesin); köprülü uygulamada köprü eksiksiz olmalı. `BundleRelocationTests` 3 hatası buydu.
- **Doğrulama (5/6):** dört ikili MACCATALYST; köprünün sistem OpenGLES bağımlılığı yok; 728 GLES export; EAGL alias + sabitler var. `EAGLGetProcAddress` hem köprüde hem GLShim'de tanımlı (ikisi de yalnız ANGLE; istemci köprüdekine bağlanıyor). `test-angle-backend/routing/geometry/exclusive` hepsi PASS. Swift: 361 test, 22 atlama, 0 hata.
- **Canlı installer testi (7) — opt-in `LiveANGLEExclusiveTests`:** `PEAR_LIVE_ANGLE_APP=<kurulu .app> PEAR_LIVE_ANGLE_LIBRARY=<test kütüphanesi>`; klon ayrı bundle ID (`.angleexclusive`), asıl oyun/kayıt değişmez. GTA LCS klonu: 10 Mach-O, 3'ü köprüye bağlı, hiçbirinde sistem OpenGLES yok, imza geçerli. Kopya `build/angle-exclusive-tests/library/com.rockstargames.gtalcs.angleexclusive.app`, ayrı home `build/angle-exclusive-tests/lcs.home`, log `build/angle-exclusive-tests/lcs-runtime.log`.

### ÇÖZÜLDÜ — GTA LCS ANGLE kopyasında siyah ekran (GLKit)

- Kök neden: GTA LCS `GLKit`'e bağlı (`GLKView` + `GLKViewController` alt sınıfı). GLKit sistem framework'ü; sistem OpenGLES'i yüklüyor (`vmmap`'teki imaj buydu) ve `GLKView` renderbuffer/framebuffer'ı **sistem** GL ile bağlayıp ayırmayı bizim `PearEAGLContext`'e yaptırıyordu → ANGLE'da bağlı renderbuffer yok: "Bind an ANGLE renderbuffer before allocating drawable storage" → her kare reddedildi.
- Düzeltme: özgün `GLKitAdapter.mm` (graphics-gl): ANGLE tabanlı `PearGLKView` (drawable/depth/stencil, bindDrawable, display, delegate) ve `PearGLKViewController` (CADisplayLink, update/glkViewControllerUpdate:, pause/resume, zaman ölçümleri). `GLKView`/`GLKViewController` sınıf+metaclass takma adları (`context-aliases.sh`) ve import/`NSClassFromString`/`objc_getClass` yönlendirmesi. GLKit kodu kullanılmadı/kopyalanmadı.
- EAGL adaptörünün ayırma/sunum hataları artık her zaman (sınırlı) loglanıyor; ayrıntı `PEAR_DEBUG_GL` ile (önceden yalnız `PEAR_GRAPHICS_BACKEND` ile, otomatik kipte hiç yazılmıyordu).
- Sonuç (ayrı kopya): "first presentation succeeded", reddedilen ayırma 0, Metal HUD 3325×1832 @ 59,83 FPS. Görsel doğrulama kullanıcıda. GLKit (ve onun yüklediği sistem OpenGLES imajı) hâlâ süreçte; oyunun GL'i ona gitmiyor. Sonraki adım: installer, bir imajın GLKit importları yalnız desteklenen sınıflarsa GLKit bağımlılığını köprüye çevirsin (sistem OpenGLES hiç yüklenmesin) — çift LC_LOAD_DYLIB'e dikkat.

### (eski not) GTA LCS ANGLE kopyasında siyah ekran

- Backend env olmadan açıldı: "ANGLE is the only GL backend", süreçte `libPearOpenGLES` + Catalyst `PearANGLE/libEGL,libGLESv2` yüklü. Pencere siyah, Metal HUD yok.
- Günlük: `renderbufferStorage fromDrawable` döngüsü — 1024×768,38 boyutunda ~894 tahsis, sonra sınırlar adım adım büyüyor (1029×772 → 1063×791 → 1083×800 → 1113×816 → 1194×855 …). ANGLE drawable, geometri değiştiği için kareyi reddediyor → hiçbir kare sunulmuyor. Önceki legacy pencere hatasına benziyor (dönüşüm sonrası bounds geri okunuyor / GL fit ↔ ANGLE geometrisi geri beslemesi). İncelenecek: `GLShim.mm` PearFitDrawable + ANGLE drawable "stale geometry" kuralı, `ScreenShim` UIScreen bounds, `LegacyWindowShim`'in GTA LCS'de devrede olup olmadığı (GTA LCS modern profil).
- `vmmap`'te sistem `OpenGLES.framework` bölgeleri de var (21 satır). Uygulama imajlarının hiçbiri ona bağlı değil; büyük olasılıkla bir sistem framework'ü (GLKit/CoreImage/AVFoundation vb.) yüklüyor. Hangi imajın yüklediği ve GL çağrısının oraya gitmediği doğrulanmalı (ör. `DYLD_PRINT_LIBRARIES=1` ile açılış).
- Test kopyası kapatıldı. Kurulu oyunlar, `/Applications` uygulaması ve kullanıcı kayıtları değiştirilmedi. Önceki Minecraft probe süreci artık çalışmıyor.

### Kalan adımlar

1. GTA LCS siyah ekran döngüsünü çöz, aynı canlı testle doğrula (görüntü + dokunma + küçük/tam ekran).
2. Sistem OpenGLES imajını kimin yüklediğini belirle.
3. Ayrı kopyada ikinci bir GL oyunu (Cut the Rope vb.) ve bir Metal oyunu (ZZZ) — Metal oyunda ANGLE'ın tembel kalıp yüklenmediğini doğrula.
4. Sonra fork→runtime→root push; release yok. arm64e/chained fixups, GLES1 sunumu, RGB565/sRGB/MSAA hâlâ desteklenmiyor.
