# PearSilicon — Çalışma Durumu (Wine / grafik)

Son güncelleme: 2026-10-31 22:50 · Dal: `feature/portable-multiplatform`
Son commit: `bf4c63f` (origin'a push edildi)
Uygulama paketi: `build/PearSilicon.app` (release, ad-hoc imzalı, `bf4c63f` gömülü)

Bu belge, bir sonraki geliştiricinin/agent'ın **kaldığı yerden devam edebilmesi**
için hazırlanmıştır. Yeni işe başlamadan önce §1 ve §4'ü oku.

---

## 1. Kısa özet

- Üç platformlu kütüphane (iOS Apps / Mac Apps / Wine Games) çalışıyor.
- Wine motoru (Wine Staging 11.21, x86_64, Gcenx paketi) çalışıyor; DELTARUNE
  başlıyor, ses geliyor, `Entering main loop` görülüyor.
- **Açık konu (2026-10-31):** Oyun penceresi wined3d ile **siyah** kalıyordu.
  Kök neden, önceki kayıtta yazıldığı gibi "her karede glClear hatası" değildir
  (o hata yalnızca bağlam ilk kurulurken 1 kez oluşuyor; ayrıntı §2.2).
- **Doğrulanmış çözüm:** DELTARUNE, **DXVK 1.10.3 (Gcenx macOS build) →
  MoltenVK → Metal** ile görüntü veriyor. Kullanıcı ekranda görüntüyü doğruladı.
- DXVK artık uygulamaya **motor düzeyinde, SHA-256 pinli bileşen** olarak entegre;
  oyun başlarken yalnız ilgili prefix'e uygulanıyor ve backend değişince geri
  alınıyor. Uçtan uca `AppState` testi geçti.

---

## 2. Kanıtlar (2026-10-31 oturumu)

### 2.1 Ortam

```
macOS 27.2 (26B123), Apple M1, harici 2560x1440@180Hz
Wine Staging 11.21 x86_64 (Rosetta 2), Gcenx paketi
DELTARUNE (GameMaker, D3D11), motor: wine-staging-11-21
```

### 2.2 Önceki "glClear" tanısı düzeltildi

`WINEDEBUG=err+d3d,err+wined3d,...` ile 30 sn'lik koşuda hata **yalnızca 1 kez**,
context init sırasında (`wined3d_context_gl_init` → `new_drawable` →
`wined3d_context_gl.c:2246` glClear) oluşuyor. Kaynak: Wine 11.21
`dlls/wined3d/context_gl.c` — bu, yeni drawable'ın ilk temizliği; kare başına
tekrarlanmıyor. Yani "her karede glClear hatası" ifadesi **yanlıştı**.

macdrv izi (`WINEDEBUG=+macdrv`) 28 sn'de:
- `macdrv_client_surface_update` 840, `macdrv_client_surface_present` 413
  (oyun penceresi 0x100a0 için 1160/2323) → oyun kare sunuyor.
- Pencere görünür, başlık `DELTARUNE Chapter 1` → `CONTACT` olarak değişiyor.
- `wined3d` hem GL hem `renderer=vulkan` (`WINE_D3D_CONFIG`) ile siyah;
  MoltenVK'nın kendisi çalışıyor (descriptor/present izleri var).
- Sonuç: sorun pencere/sunum zincirinde değil, **wined3d'nin ürettiği içerikte**.

### 2.3 DXMT bu motorda çalışamıyor (kanıt)

1. DXMT `-builtin` arşivi upstream talimatına göre kurulunca
   (`<runtime>/lib/wine/x86_64-windows/{d3d11,dxgi,d3d10core,winemetal}.dll`,
   `x86_64-unix/winemetal.so`, system32'de `winemetal.dll`, **override yok**)
   Wine gerçekten DXMT'yi yükledi; oyun `DirectX11: Using hardware device`
   dedikten sonra:
   ```
   err:   Failed to create metal view, it seems like your Wine has no exported symbols needed by DXMT.
   ```
   ve `abort()` ile çıktı.
2. Neden: DXMT `src/winemetal/unix/winemetal_unix.c` içinde
   `dlsym(RTLD_DEFAULT, "macdrv_functions")` / `macdrv_view_create_metal_view`
   / `get_win_data` sembollerini arıyor. Gcenx Wine'ın
   `Runtime/lib/wine/x86_64-unix/winemac.so` dosyasında **yalnızca**
   `___wine_unix_call_funcs` ve `___wine_unix_call_wow64_funcs` export ediliyor
   (`nm -gU`). Semboller `-fvisibility=hidden`/strip nedeniyle yok.
3. DXMT'yi `WINEDLLPATH` + `d3d11=n,b` ile denemek de yanlış: Wine'ın builtin
   arama sırası önce `lib/wine` (dll_dir), sonra `WINEDLLPATH`. Bu yüzden
   motorun 417 KB builtin `d3d11.dll`'i yükleniyordu (5.35 MB DXMT değil).
4. Sonuç: DXMT, winemac metal API'sini export eden bir Wine derlemesi
   (CrossOver tabanlı) gerektiriyor; Gcenx otomatik motorlarında mümkün değil.

### 2.4 Çalışan çözüm: DXVK-macOS

- Sürüm: `Gcenx/DXVK-macOS` release `v1.10.3-20230507-repack`,
  asset `dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz`
  - SHA-256 (tarball): `acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477`
  - x64/d3d11.dll: `0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4`
  - x64/d3d10core.dll: `0fa08bba860c63e3abeeabfc96d0e7aa327411a975f8f23d2dc63594ef5f796e`
- Kurulum: DLL'ler prefix `drive_c/windows/system32` içine, override
  `WINEDLLOVERRIDES="d3d11,d3d10core=n;winemenubuilder.exe=d"`,
  `VK_ICD_FILENAMES=<runtime>/share/vulkan/icd.d/MoltenVK_icd.json`.
- Sonuç: DXVK `v1.10.3-20230507-async (macOS)` yüklendi, MoltenVK
  `CAMetalLayer: WineMetalView ... on screen Main Screen` ile 1280x960
  swapchain kurdu, oyun `Entering main loop` ve **görüntü kullanıcı tarafından
  doğrulandı**.
- Not: DXVK 2.x/3.x burada çalışmaz; MoltenVK `geometryShader` sunmadığı için
  cihaz reddedilir (test edildi: "Device does not support required feature
  'geometryShader'"). Bu yüzden 1.10.3 macOS yaması pinlendi.
- Deney betikleri: `.build/dxvk-start.sh`, `.build/dxvk-stop.sh`,
  `.build/dxvk-test.sh`, `.build/dxmt-builtin-diag.sh`, `.build/window-list.swift`.
  (Bunlar teşhis betikleridir; uygulama kodu değildir.)

---

## 3. Uygulama entegrasyonu (tamamlandı)

Hedef: DXVK'yı DXMT/KosmicKrisp gibi **motor düzeyinde indirilebilir bileşen**
yapmak; her oyunun `graphicsBackend` seçimine göre yalnız o oyunun prefix'ine
uygulamak; geri alınabilir olmak.

Uygulama:
- Bileşen: `<engine>/Graphics/DXVK/x64/{d3d11,d3d10core}.dll`
  (`GraphicsComponentService.installDXVK`, arşiv + DLL'ler SHA-256 pinli).
- Uygulama: backend `.moltenVK` ve bileşen kuruluysa, oyun başlarken prefix
  `system32`'ye kopyalanır; Wine'ın orijinalleri `Prefix/pear-dxvk-backup/`
  altına yedeklenir; `Prefix/pear-dxvk.json` hangi dosyaların bizim olduğunu
  kaydeder.
- Geri alma: backend değişince (ör. DXMT) veya bileşen kaldırılınca yedekler
  geri konur; DXVK'ya ait olmayan (marker/hash eşleşmeyen) dosya **silinmez**.
- Env: yalnız bu durumda
  `WINEDLLOVERRIDES="d3d11,d3d10core=n;winemenubuilder.exe=d"`.
- UI: oyun detayında "Install DXVK" düğmesi ve durum uyarısı; Settings →
  Wine'da bileşen lisans notu.
- DXMT: `launchConfiguration` artık winemac'in Metal view sembollerini
  denetliyor; Gcenx motorlarında DXMT net bir hatayla reddediliyor (siyah
  pencereye/sessiz başarısızlığa düşmüyor).

Değişen/eklenen dosyalar:
`Sources/PearSilicon/Core/Services/GraphicsComponentService.swift`,
`Sources/PearSilicon/Core/Services/ManagedAppService.swift`,
`Sources/PearSilicon/Core/Models/LibraryEntry.swift`,
`Sources/PearSilicon/App/AppState.swift`,
`Sources/PearSilicon/Views/ManagedAppDetailView.swift`,
`Sources/PearSilicon/Views/SettingsView.swift`,
`Tests/PearSiliconTests/DXVKComponentTests.swift`,
`Tests/PearSiliconTests/GraphicsComponentIntegrationTests.swift`,
`Tests/PearSiliconTests/AppStateWineIntegrationTests.swift`,
`Tests/PearSiliconTests/WineEngineTests.swift`,
`README.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`,
`STATUS.md`, `HYPOTHESES.md`, `DEBUG_JOURNAL.md`.

---

## 4. Sıradaki kesin adım

1. ~~`swift build` + `swift test`~~ → **279 XCTest + 24 Swift Testing, 0 hata,
   13 opsiyonel skip** (`/tmp/pear-full-test-final.log`).
2. ~~DXVK bileşenini gerçek motora kur~~ → kuruldu, DLL hash'leri pinlerle
   eşleşiyor.
3. ~~Gerçek DELTARUNE'ı uygulama yolundan (AppState) başlat~~ →
   `PEAR_DXVK_E2E=1` testi geçti: logda `DXVK: v1.10.3` + `Entering main loop`,
   süreç ayakta, test sonunda durduruldu. Görsel onay daha önce alındı.
4. ~~Uygulama paketini yeniden derle~~ → `build/PearSilicon.app` `bf4c63f` ile
   derlendi ve ad-hoc imzası doğrulandı. Kullanıcı bu paketi açmalı; çalışan eski
   uygulama izinsiz kapatılmadı (oturum sonunda zaten çalışmıyordu). Değişiklikler
   `feature/portable-multiplatform` dalına commit + push edildi.

Sonraki iyileştirmeler (acil değil):
- DXVK bileşeni için "Kaldır" düğmesi ve sürüm durumu; şu an kurulum var, kaldırma
  dosya sistemi üzerinden backend değişimiyle otomatik.
- DXMT'yi gerçekten çalıştırmak isteyenler için winemac metal API'sini export eden
  bir motor (CrossOver tabanlı) desteği; otomatik Gcenx motorlarında mümkün değil.
- 32-bit (syswow64) DXVK dağıtımı; uygulama şu an x86_64 odaklı.
- `docs/TESTING.md`'ye yeni bileşen testlerinin manuel kontrol listesi.

---

## 5. Gerçek ortam / kütüphane düzeni

```
~/Library/Application Support/PearSilicon/
  ios-apps/  mac-apps/  wine-apps/DELTARUNE/
  Engines/wine-staging-11-21/
    Runtime/                 (Wine Staging 11.21 x86_64, SHA-256 doğrulandı)
    Graphics/DXMT/           (kurulu; bu motorda çalışamaz — §2.3)
    Graphics/DXVK/           (kurulu; pinli 1.10.3, x64)
  wine-apps/DELTARUNE/Prefix/
    dosdevices/{c: -> ../drive_c, g: -> ../../Payload/Program}
    drive_c/windows/system32/{d3d11,d3d10core}.dll  (DXVK)
    pear-dxvk.json  pear-dxvk-backup/               (geri alma kaydı)
```

- DELTARUNE manifest: `graphicsBackend: "moltenvk"` (DXVK bu backend altında).
- Oyun kendini yeniden başlatıyor (`-game data.win launcher switch_-1 returning_0`);
  bu normaldir; ilk süreç kısa ömürlüdür.
- Test oyunları için kullanıcının açık oyununu izinsiz kapatmayın;
  `.build/*-start.sh` / `.build/*-stop.sh` çiftini kullanın.

---

## 6. Doğrulama durumu (bu oturum)

| Alan | Durum |
| --- | --- |
| `swift build` | temiz |
| `swift test` | **279 XCTest** + **24 Swift Testing**, 0 hata, 13 opsiyonel skip |
| Wine motoru | gerçek indirme + SHA-256 + kurulum + DELTARUNE ✓ |
| wined3d GL | siyah (kullanıcı doğruladı) |
| wined3d Vulkan renderer | siyah (kullanıcı doğruladı) |
| DXMT (builtin kurulum) | yükleniyor, metal view'da abort (§2.3) |
| DXMT backend guard | winemac sembolleri yoksa net hata (test: `testEngineWithoutExportedMetalViewAPICannotSelectDXMT`) |
| DXVK 1.10.3 + MoltenVK | **görüntü var** (kullanıcı doğruladı) |
| DXVK AppState E2E | logda DXVK + main loop, süreç ayakta ✓ |
| DXVK prefix backup/restore | birim testleri ✓ |

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
  olmadığı için çalışmaz. Yeni oyunlarda uyumluluk sınırlı olabilir.
- DXVK yalnız x86_64 DLL'leri kurulur (uygulama x86_64 Wine kullanıyor).
- DXMT otomatik motorlarda çalışmaz; UI'da bunu açıkça belirtmek gerekir.
- Mac uygulamaları native çalışır; izolasyon yok.
- Wine VM değildir; kernel anti-cheat çalışmaz; Rosetta 2 gerekir.
- KosmicKrisp yalnız arm64; x86_64 motorlarda reddedilir.
- Yedekler şifresiz; uygulama ad-hoc imzalı, noterize değil.
