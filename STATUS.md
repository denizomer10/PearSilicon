# PearSilicon — Çalışma Durumu

Son güncelleme: 2026-11-01 10:30 · Dal: `feature/portable-multiplatform`
Son commit: `7284687` (origin'a push edildi)
Uygulama paketi: `build/PearSilicon.app` (release, ad-hoc imzalı, `7284687` gömülü)

Bir sonraki geliştirici/agent §1 ve §4'ü okuyarak kaldığı yerden devam edebilir.

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
  8. Disk temizliği: 31 GB `.build` test çöpü ve yeniden üretilebilir cache'ler
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
4. ~~Değişiklikleri commit + push et~~ → `7284687` push edildi; uygulama paketi
   `7284687` ile yeniden derlendi ve ad-hoc imzası doğrulandı.
5. Kullanıcı `/Applications/PearSilicon.app` (eski, çalışıyor) yerine
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
| `swift test` | **285 XCTest + 24 Swift Testing, 0 hata, 14 opsiyonel skip** (son koşu) |
| Güncelleme kanalları | liste tabanlı seçim testleri ✓ |
| Community GitHub | URL ayrıştırma + gerçek repo çözümleme testi ✓ |
| Motor kaldırma | birim testi ✓ |
| KosmicKrisp kaldırma | derleme + testler ✓ |
| Controller kimlik/replay | Catalyst probe ile doğrulandı ✓ |
| Controller/Genshin | runtime güncellendi; **oyun yeniden başlatılınca** doğrulanacak |
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
