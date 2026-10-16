# TP-Link EX20v v2 OpenWrt Kurulum Aracı

Bu depo, TP-Link EX20v v2 cihazında stok firmware yedeği almak, OpenWrt kurmak,
açılış slotunu yönetmek ve gerektiğinde cihazın kendi yedeğinden stok firmware'e
dönmek için hazırlanmış tek dosyalık Windows aracıdır.

Kurulum ve kurtarma işlemlerinin tamamı çift tıklanarak çalıştırılabilen
`ex20v-tool.exe` tarafından yönetilir. Python, Tftpd64 veya ayrı shell scriptleri
çalıştırmak gerekmez. Araç gerekli HTTP/TFTP sunucularını geçici olarak kendisi
açar ve `files` klasöründeki firmware imajlarını kullanır. PowerShell kaynak kodu
inceleme ve geliştirme amacıyla `ex20v-tool.ps1` dosyasında tutulur. Derlenmiş
EXE kaynak depoda tutulmaz; GitHub Releases bölümündeki hazır ZIP paketinde
sunulur.

Bu çalışma; [OpenWrt](https://github.com/openwrt/openwrt) topluluğunun,
EcoNet için geliştirilen açık kaynak sürücülerin ve daha önce EX20v üzerinde
çalışan geliştiricilerin emeği sayesinde hazırlanabilmiştir. Ayrıntılı katkı
ve kaynak bilgileri [Teşekkür ve kaynaklar](#teşekkür-ve-kaynaklar) bölümündedir.

> [!WARNING]
> Bu işlemler NAND flash belleğe doğrudan yazar. Elektrik kesintisi, yanlış
> firmware, farklı donanım revizyonu veya beklenmeyen NAND problemi cihazı
> kullanılamaz hale getirebilir. Seri konsol (UART) ile kurtarma gerekebilir.
> Bütün işlemlerin riski kullanıcıya aittir.

## Desteklenen cihaz

- Model: **TP-Link EX20v v2**
- Hedef sistem: Depodaki imajların üretildiği EX20v v2 OpenWrt bölüm düzeni
- Kurulum bilgisayarı: Windows 10 veya Windows 11
- Bağlantı: Ethernet kablosu

Bu aracı EX20v v1, farklı donanım revizyonu veya başka TP-Link modellerinde
kullanmayın. Script bölüm adlarını ve boyutlarını denetlese de yanlış cihazda
deneme yapılması güvenli değildir.

## Çok önemli ön koşul: root erişimi

İlk yedek ve OpenWrt kurulumu için stok firmware üzerinde **root SSH erişimi
önceden açılmış olmalıdır**. Bu araç root erişimini açmaz; mevcut erişimi
kullanır.

Stok firmware'in standart bilgileri araçta tanımlıdır:

- SSH/Linux kullanıcısı: `root`
- Varsayılan parola: `Root2025.`

Parola değiştirilmişse araç başarısız olmak yerine yeni parolayı maskeli olarak
sorar. TP-Link komut arayüzünün SSH parolası ile `shell` komutundan sonraki
Linux parolası birbirinden farklıysa ikisini ayrı ayrı isteyebilir.

## Depo içeriği

```text
openwrt-ex20v-v2/
├── ex20v-tool.ps1
├── icon.png
├── files/
│   ├── ex20v-rescue.bin
│   ├── ex20v-kernel.bin
│   ├── ex20v-ubi.bin
│   └── ex20v-v2-sysupgrade.bin
├── README.md
├── .gitattributes
└── .gitignore
```

| Dosya | Kullanım amacı |
| --- | --- |
| `ex20v-tool.ps1` | Aracın okunabilir PowerShell kaynak kodu |
| `icon.png` | EXE dosyasına gömülen uygulama ikonunun kaynak görseli |
| `ex20v-rescue.bin` | Slot A'da çalışan RAM tabanlı rescue OpenWrt |
| `ex20v-kernel.bin` | Slot B'deki ana OpenWrt kerneli |
| `ex20v-ubi.bin` | Ana OpenWrt UBI/rootfs imajı |
| `ex20v-v2-sysupgrade.bin` | Kurulu OpenWrt'yi daha sonra güncellemek için sysupgrade imajı |

`Backups` klasörü ilk çalıştırmada otomatik oluşturulur. Cihaza özel yedekler
Git'e eklenmez.

## GitHub Release paketi

Normal kullanıcılar kaynak kod ZIP'i yerine GitHub Releases bölümünde yayımlanan
`EX20v-v2-OpenWrt-Tool-v1.0.0.zip` dosyasını indirmelidir. Paket açıldığında şu
yapı oluşur:

```text
EX20v-v2-OpenWrt-Tool-v1.0.0/
├── ex20v-tool.exe
├── README.md
└── files/
    ├── ex20v-rescue.bin
    ├── ex20v-kernel.bin
    ├── ex20v-ubi.bin
    └── ex20v-v2-sysupgrade.bin
```

EXE ile `files` klasörünü birbirinden ayırmayın. Derlenmiş EXE ve yerel `dist`
klasörü `.gitignore` kapsamındadır; bunlar kaynak depoya commit edilmez.

### Windows aracının bütünlük bilgisi

| Dosya | Sürüm | Boyut | SHA256 |
| --- | --- | ---: | --- |
| `ex20v-tool.exe` | 1.0.0.0 | 117.760 bayt | `1d1de36fb38e10f23943fe1fb578036e16625d60e79d29453577593c848b6a5c` |

EXE, 64 bit Windows için PowerShell kaynak kodundan üretilmiş ve `icon.png`
görseli çok çözünürlüklü Windows ikonu olarak dosyaya gömülmüştür. EXE'nin
dijital kod imzası yoktur. Dosyayı farklı bir kaynaktan aldıysanız çalıştırmadan
önce SHA256 değerini karşılaştırın.

## Paketle gelen imajlar

Bu depodaki mevcut imajların boyut ve SHA256 değerleri:

| Dosya | Boyut | SHA256 |
| --- | ---: | --- |
| `ex20v-rescue.bin` | 6.083.941 bayt | `7b8ce917f6f221e69ee3ca3e80450319952c64a472ddc454282179f3c4a3d5b8` |
| `ex20v-kernel.bin` | 3.554.102 bayt | `6a3d8c12373fd212b1fbd22b9e56e86618a2b713b4a000ffb8e035fbaf39420a` |
| `ex20v-ubi.bin` | 6.815.744 bayt | `cd7497fa694addc14e6a7e6a76619dda9ef32984266e42b5cd2abb177f179782` |
| `ex20v-v2-sysupgrade.bin` | 8.345.870 bayt | `951e75e9f642f8eb0e3c3a5e493caff79390aabb04708276e1d0782ebf741af2` |

Ana menüdeki `5 - Dosyaları ve gereksinimleri kontrol et` seçeneği dosya
başlıklarını, boyutları ve hesaplanan SHA256 değerlerini gösterir.

## Gereksinimler

- Stok firmware üzerinde çalışan root SSH erişimi
- Windows 10/11 ve Windows PowerShell 5.1
- Windows OpenSSH Client
- Ethernet kablosu
- Tam yedek için bilgisayarda en az 450 MB boş alan
- Kurulum boyunca kesilmeyecek güç bağlantısı
- Mümkünse doğrudan PC–router bağlantısı

Windows Güvenlik Duvarı ilk aktarımda ağ erişimi isteyebilir. Özel ağ erişimine
izin verin. Araç varsayılan olarak TCP/UDP `8000` portunu kullanır.

## Aracı başlatma

1. GitHub Releases bölümünden hazır ZIP paketini indirin.
2. ZIP'in tamamını bir klasöre çıkarın; EXE'yi arşivin içinden çalıştırmayın.
3. `ex20v-tool.exe` dosyasına çift tıklayın.
4. Windows UAC penceresinde yönetici iznini onaylayın.
5. Ana menü otomatik açılır.

Önceden terminal açıp komut yazmanız gerekmez. EXE yönetici yetkisi isteyen bir
Windows manifesti içerir. Menüde `Yönetici yetkisi: etkin` bilgisi görünür.

EXE dijital olarak imzalanmadığı için Windows SmartScreen ilk çalıştırmada uyarı
gösterebilir. Dosyayı projenin GitHub Releases bölümünden indirdiğinizi ve
yukarıdaki SHA256 değerinin eşleştiğini doğruladıktan sonra **Ek bilgi** ve
**Yine de çalıştır** seçeneklerini kullanabilirsiniz. Windows dosyayı engellerse
EXE'ye sağ tıklayın, **Özellikler** penceresindeki **Engellemeyi kaldır**
seçeneğini işaretleyip yeniden çalıştırın.

Kaynak sürümü çalıştırmak isteyen geliştiriciler `ex20v-tool.ps1` dosyasına sağ
tıklayıp **PowerShell ile çalıştır** seçeneğini kullanabilir. EXE ve PS1 aynı
işlevleri sunar; normal kullanım için EXE önerilir.

## Ana menü

```text
1) Stok firmware tam yedeği al
2) OpenWrt kurulumu
3) Stok firmware geri yükleme
4) Kurtarma ve açılış slotu
5) Dosyaları ve gereksinimleri kontrol et
0) Çıkış
```

İlk kurulum için önerilen sıra:

1. Tam stok yedeğini alın.
2. Rescue OpenWrt'yi slot A'ya kurun.
3. Rescue sistemi açın.
4. Ana OpenWrt'yi slot B ve UBI alanına kurun.

## 1. Tam stok firmware yedeği

OpenWrt kurmadan önce bu adımı mutlaka tamamlayın.

1. Bilgisayarı stok firmware'in LAN ağına bağlayın.
2. Ana menüden `1` seçin.
3. Router'ın mevcut SSH adresini girin; örnek: `root@192.168.1.3`.
4. Router'ın erişebileceği bilgisayar IPv4 adresini doğrulayın.
5. İşlem tamamlanana kadar bağlantıyı ve gücü kesmeyin.

Yedekleme flash belleğe yazmaz. Aşağıdaki bölümleri ve reserve alanını okur:

- boot
- romfile
- config
- radio
- slot A kernel/rootfs
- slot B kernel/rootfs
- reserve_area parçaları

Çıktılar tarih-saat klasörüne kaydedilir:

```text
Backups/YYYYMMDD-HHMMSS/
```

Her dosya için MD5 oluşturulur ve bilgisayarda tekrar doğrulanır. Tam bir yedek
yaklaşık 450 MB alan kullanır. Bu klasörü ayrıca güvenli bir yerde saklayın;
başka cihazın yedeğini kullanmayın.

## 2. OpenWrt kurulumu

Kurulum iki aşamalıdır. Script her aşamadan önce seçilen yedeğin bütünlüğünü
kontrol eder.

### Aşama 1/2 — stok sistemden rescue kurulumu

1. Stok firmware'in slot B'den çalıştığından emin olun.
2. Ana menüden `2`, ardından `1` seçin.
3. Tam yedeği seçin.
4. Stok SSH hedefini ve bilgisayarın LAN IP adresini girin.
5. İstenen açık onay kelimesini yazın.

Araç `ex20v-rescue.bin` dosyasını slot A kernel alanına yazar, yazılan veriyi
tekrar okuyarak doğrular ve yalnızca doğrulama başarılı olursa bootflag'i `0`
yapar.

Yeniden başlatmadan önce:

- Bilgisayarın Ethernet adresini `192.168.1.2/24` yapın.
- Kabloyu LAN1, LAN2 veya LAN3 portlarından birine bağlayın.

### Aşama 2/2 — rescue üzerinden ana OpenWrt kurulumu

1. Cihaz rescue ile açıldıktan sonra scripti yeniden başlatın.
2. Ana menüden `2`, ardından `2` seçin.
3. SSH hedefi için varsayılan `root@192.168.1.1` değerini kullanın.
4. Bilgisayar IP adresi olarak `192.168.1.2` değerini doğrulayın.
5. İstenen açık onay kelimesini yazın.

Araç ana kerneli slot B'ye, UBI imajını birleşik rootfs alanına yazar. Yazma
kontrolleri tamamlandıktan sonra bootflag `1` yapılır. Yeniden açıldığında web
arayüzü varsayılan olarak şu adrestedir:

```text
http://192.168.1.1
```

İlk OpenWrt açılışında root parolası yoktur. LuCI veya `passwd` ile güçlü bir
parola belirleyin.

## 3. Stok firmware'e geri dönüş

Stoka dönüş için aynı cihazdan alınmış tam yedek zorunludur. İşlem iki aşamaya
ayrılır; ilk aşamada rescue korunarak geri dönüş imkânı bırakılır.

### Aşama 1/2 — rescue üzerinden stok slot B'yi geri yükleme

1. Ana OpenWrt çalışıyorsa menüden `4`, ardından `2` ile slot A/rescue'yu seçip
   cihazı yeniden başlatın.
2. Bilgisayarı `192.168.1.2/24` adresine alın.
3. Ana menüden `3`, ardından `1` seçin.
4. Cihazın kendi tam yedeğini seçin.
5. İstenen onay kelimesini yazın.

Araç önce ROMFILE ve radio kimliklerini yedekle karşılaştırır. Ardından stok
slot B kernel/rootfs ile reserve_area içeriğini geri yükler. Her parça yazıldıktan
sonra flash'tan tekrar okunup MD5 ile doğrulanır. Slot A'daki rescue bu aşamada
korunur ve bootflag yalnızca bütün doğrulamalar başarılı olursa `1` yapılır.

### Aşama 2/2 — stok açıldıktan sonra slot A'yı tamamlama

1. Stok firmware'in slot B'den sorunsuz açıldığını doğrulayın.
2. Yönetim arayüzü, Ethernet ve SSH erişimini kontrol edin.
3. Ana menüden `3`, ardından `2` seçin.
4. Aynı tam yedeği seçin.
5. Stok SSH hedefini girip istenen onay kelimesini yazın.

Bu aşama yalnızca stok sistem gerçekten slot B'den çalışıyorsa başlar. Aktif
olmayan slot A kernel/rootfs yedekten geri yüklenir ve tekrar okunarak
doğrulanır. İşlem sonunda her iki slot da stok durumdadır; cihaz slot B üzerinde
çalışmaya devam eder.

Stok firmware'deki küçük `/tmp` alanı sorun oluşturmaz. Araç geçici dosyalar
için yeterli boş RAM alanını otomatik seçer.

## 4. Kurtarma ve açılış slotu

Bu menü aşağıdaki işlemleri sunar:

- Çalışan sistemi ve bootflag değerini salt okunur gösterme
- Sonraki açılışı slot A/rescue olarak ayarlama
- Sonraki açılışı slot B/ana sistem olarak ayarlama

Bağlanılan sistem türünü doğru seçin:

- Stok firmware SSH
- Rescue OpenWrt SSH
- Ana OpenWrt SSH

Ana OpenWrt açılmıyorsa slot A/rescue'yu seçip cihazı yeniden başlatın ve ana
kurulum aşamasını tekrarlayın. SSH erişimi tamamen kaybolmuşsa bu aracın dışında
UART kurtarma gerekebilir.

## 5. Yerel dosya ve gereksinim kontrolü

Bu seçenek flash belleğe yazmaz. Aşağıdakileri kontrol eder:

- Dört firmware dosyasının varlığı
- Rescue ve kernel boyut sınırları
- TP-Link kernel başlığı ve giriş adresi
- UBI imza bilgisi
- Dosyaların SHA256 değerleri
- Windows OpenSSH istemcisinin varlığı
- Yerel IPv4 adresleri
- Kullanılabilir yedek klasörleri

Kurulum öncesi bu kontrolü çalıştırmak önerilir.

## Parola ve SSH davranışı

Araç sistemleri birbirinden ayırır:

- Stok firmware önce `root / Root2025.` ile denenir.
- Stok SSH parolası farklıysa maskeli olarak sorulur.
- `shell` sonrasındaki Linux parolası farklıysa ayrıca sorulur.
- Rescue ve ana OpenWrt önce parolasız root veya SSH anahtarıyla denenir.
- Kimlik doğrulama reddedilirse ilgili OpenWrt root parolası maskeli sorulur.

Girilen parolalar dosyaya veya README'ye yazılmaz. Yalnızca çalışan PowerShell
ve SSH işlemlerinin belleğinde geçici olarak tutulur. Stok parolası OpenWrt
bağlantısında kullanılmaz.

Stok firmware'in eski SSH sunucusu için gereken `ssh-rsa` uyumluluğu yalnızca
stok bağlantısına uygulanır. Rescue ve ana OpenWrt güncel OpenSSH ayarlarını
kullanır. Stok ve rescue sistemleri her açılışta yeni host key üretebildiği için
bu iki ortamın geçici host key kayıtları otomatik yenilenir.

## Güvenlik kontrolleri

Script yazma işleminden önce ve sonra çok katmanlı kontroller uygular:

- Cihazın beklenen EX20v v2 MTD düzenine sahip olması
- Doğru sistem ve doğru slot üzerinde çalışılması
- İmajların bulunması, boyut sınırları ve temel başlıkları
- Seçilen yedeğin bütün dosya boyutları ve MD5 değerleri
- Stok geri dönüşünde ROMFILE/radio ile aynı-cihaz doğrulaması
- Yazılan kernel ve stok bölümlerinin tekrar okunup doğrulanması
- Bootflag'in kritik yazmalar bittikten sonra en son değiştirilmesi
- Flash yazan işlemler için açık onay kelimesi

Bu kontroller riski azaltır; elektrik kesintisi veya donanım arızasına karşı
garanti vermez.

## Yeni OpenWrt sürümü kullanmak

İleride yeni bir EX20v v2 OpenWrt sürümü çıktığında `files` klasöründeki dört
dosya aynı adlarla değiştirilebilir. Ancak yalnızca dosya adlarının aynı olması
yeterli değildir.

Yeni dosyalar:

- Kesinlikle TP-Link EX20v v2 için üretilmiş olmalı.
- Mevcut MTD/slot düzenini kullanmalı.
- Rescue ve ana sistem aynı uyumlu derleme grubundan gelmeli.
- `ex20v-rescue.bin` ve `ex20v-kernel.bin` 6 MiB sınırını aşmamalı.
- `ex20v-ubi.bin` bu cihazın birleşik UBI bölümüne uygun olmalı.

İlk kurulum akışı `ex20v-rescue.bin`, `ex20v-kernel.bin` ve `ex20v-ubi.bin`
dosyalarını kullanır. `ex20v-v2-sysupgrade.bin`, kurulu OpenWrt'yi LuCI veya
`sysupgrade` üzerinden güncellemek içindir.

Bölüm düzenini değiştiren bir sürüm için yalnızca dosyaları değiştirmeyin;
scriptin de yeni düzene göre güncellenmesi gerekir. Farklı sürümlere ait rescue,
kernel ve UBI dosyalarını karıştırmayın.

## Ağ ve aktarım davranışı

- Araç yerel IPv4 adreslerini listeler.
- `192.168.1.x` adresleri Docker/WSL gibi sanal ağlardan önce tercih edilir.
- Seçilen bilgisayar IP'sine router tarafından erişilebilmelidir.
- HTTP indirmeleri ve TFTP yedekleri araç içindeki geçici sunucularla yapılır.
- Sunucular işlem bitince otomatik kapatılır.
- Varsayılan aktarım portu `8000`'dir.

Bir VPN, sanal adaptör veya ikinci Ethernet/Wi-Fi bağlantısı yanlış rota
oluşturuyorsa geçici olarak devre dışı bırakın ve PC'nin router ile aynı ağdaki
IPv4 adresini elle seçin.

## Sorun giderme

### Root SSH bağlantısı kurulamıyor

- Stok firmware'de root erişiminin gerçekten açıldığını doğrulayın.
- Router IP adresini kontrol edin.
- Ethernet bağlantısını kullanın.
- Parola sorulursa stok SSH parolasını girin.
- `shell` sonrası ayrıca parola sorulursa Linux shell parolasını girin.

### Router bilgisayardaki dosya sunucusuna erişemiyor

- Router ile aynı ağdaki `192.168.1.x` bilgisayar adresini seçin.
- Windows Güvenlik Duvarı'nda özel ağ erişimine izin verin.
- TCP/UDP `8000` portunu kullanan başka uygulama olmadığını kontrol edin.
- VPN ve sanal ağ adaptörlerini geçici olarak kapatmayı deneyin.

### Rescue sistemine erişilemiyor

- Bilgisayar adresini `192.168.1.2/24` yapın.
- `root@192.168.1.1` hedefini kullanın.
- Kabloyu LAN1, LAN2 veya LAN3 portuna bağlayın.
- Cihazın bootflag değerinin slot A/rescue (`0`) olduğunu kontrol edin.

### Yedek doğrulaması başarısız

Eksik veya MD5 değeri uyuşmayan yedeği kullanmayın. Stok firmware çalışıyorsa
yeni bir tam yedek alın. Yarım kalmış yedek klasörleri tanılama amacıyla
korunur ancak kurulum için kabul edilmez.

### İşlem hata ile durdu

Hata yazma başlamadan oluşmuşsa flash değişmemiş olabilir. Yazma başladıktan
sonra hata oluştuysa cihazı hemen yeniden başlatmayın; ekrandaki son başarılı
adımı ve hata mesajını kaydedin. Rescue slotu çalışıyorsa işlemi aynı doğrulanmış
yedek ve imajlarla tekrar başlatın.

### Terminal yazıları kayıyor

Güncel script Windows terminali ile Linux shell arasındaki satır sonlarını
otomatik düzeltir. Eski bir kopya kullanmadığınızdan emin olun.

## Yedeklerin korunması

`Backups` klasörü cihaza özel ve kritik veri içerir. Özellikle ROMFILE, radio,
config ve reserve_area başka cihazla paylaşılmamalıdır. Bu klasörü:

- GitHub'a yüklemeyin.
- Herkese açık arşivlere eklemeyin.
- Cihaz seri bilgileri içerebileceği için özel tutun.
- En az bir ayrı diskte kopyalayın.

Depodaki `.gitignore`, `Backups/` klasörünün yanlışlıkla Git'e eklenmesini
engeller.

## Teşekkür ve kaynaklar

Bu aracın ve beraberindeki OpenWrt imajlarının ortaya çıkmasını mümkün kılan
açık kaynak geliştiricilerine ve topluluk üyelerine teşekkür ederiz:

- [OpenWrt Projesi](https://github.com/openwrt/openwrt) — açık kaynak işletim sistemi, derleme altyapısı ve EcoNet EN7528 hedefi için.
- [Caleb James DeLisle](https://github.com/cjdelisle) — [`econet_eth`](https://github.com/cjdelisle/econet_eth) Ethernet sürücüsü ve EcoNet platformuna yaptığı katkılar için.
- [Emre Yavuzalp](https://github.com/EmreYavuzalp) — EX20v v1 OpenWrt portundaki öncü teknik çalışmaları ve [`EmreYavuzalp/openwrt-tplink-ex20v`](https://github.com/EmreYavuzalp/openwrt-tplink-ex20v) deposunu topluluğa sunduğu için.
- [Özgün Okan](https://github.com/ozgunokan) — EX20v OpenWrt çalışmalarına katkıları ve [`ozgunokan/openwrt-tplink-ex20v`](https://github.com/ozgunokan/openwrt-tplink-ex20v) deposunu topluluğa sunduğu için. EX20v v2 desteğinde yararlanılan Ethernet/PPE davranışı, LED ve düğme GPIO'ları, port eşlemesi, firewall4 flowtable düzeni ve mt76 MAC yaklaşımı Özgün Okan tarafından geliştirilmiştir.
- [Laserbird](https://github.com/laserbirdx) — EX20v OpenWrt geliştirme sürecinde sağladığı değerli destek, teknik yardımlar ve sorunların çözümüne yönelik katkıları için.
- [Markus Scholtes](https://github.com/MScholtes/PS2EXE) ve Ingo Karstein — PowerShell aracını Windows EXE dosyasına dönüştürmekte kullanılan açık kaynak PS2EXE projesi için.
- Cihaz üzerinde deneme yapan, hata bildiren ve geri bildirim sağlayan tüm topluluk üyeleri.

Bu proje bağımsız bir topluluk çalışmasıdır. TP-Link, Türk Telekom, EcoNet,
MediaTek veya OpenWrt projesiyle resmî bir bağı yoktur ve bu kuruluşlar
tarafından onaylanmamıştır. Adı geçen marka ve ürün adları yalnızca cihazı ve
kullanılan teknolojileri tanımlamak amacıyla kullanılmıştır.

## Sorumluluk ve servis sağlayıcı cihazları

EX20v cihazı internet servis sağlayıcısına ait veya kiralık olabilir. Firmware
değiştirmek sözleşme şartlarını ihlal edebilir; VoIP, DSL, TR-069, uzaktan destek
ve garanti hizmetlerini etkileyebilir. Cihaz size ait değilse işlemden önce
servis sağlayıcınızdan izin alın.

Bu yazılım herhangi bir başarı, uyumluluk veya kurtarılabilirlik garantisi
vermeden sunulur. Yanlış kullanım, veri kaybı, bağlantı kesintisi, cihaz hasarı
ve sözleşmesel sonuçlardan kullanıcı sorumludur.
