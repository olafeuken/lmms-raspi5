# lmms-raspi5

Budowa **LMMS** dla **Raspberry Pi 5** (Broadcom BCM2712, CPU **Cortex-A76**, aarch64)
zoptymalizowana pod maksymalne wykorzystanie zasobów, **wielowątkowość** i **ochronę
przed OOM oraz przeciążeniem CPU** — kompilowana przez **GitHub Actions** na
darmowym, natywnym runnerze ARM64.

---

## 1. Analiza SoC i systemu (na czym oparto build)

| Parametr | Wartość | Wniosek dla buildu |
|---|---|---|
| CPU | 4 × **Cortex-A76** (BCM2712), bez SMT | 4 rdzenie, 1 wątek/rdzeń → `OMP_NUM_THREADS=4` |
| Architektura | aarch64 (ARMv8.2-A) | kompilacja natywna arm64 |
| Feature-y | `asimddp` (dotprod), `fphp/asimdhp` (fp16), `atomics` (LSE), `lrcpc`, `crc32`, `aes/sha`, `dcpop` | dokładny zestaw **Cortex-A76** |
| Takt | 1500–3000 MHz (governor `performance`, overclock) | flagi pod A76 dają pełny zysk |
| L2 | 2 MB (współdzielone) | tuning `-mcpu` istotny dla pętli DSP |
| RAM | 7,8 GB + zram (4×) | limity pamięci — patrz §3 |
| OS | Debian 13 (trixie), KDE Plasma 6, Wayland, PipeWire | backend **PulseAudio** (przez pipewire-pulse) = stabilny |

### Dlaczego `-mcpu=cortex-a76`?
`-mcpu=cortex-a76` ustawia jednocześnie `-march=armv8.2-a` **i** `-mtune`, dobierając
wszystkie cechy A76 (LSE, dotprod, crypto, fp16, rcpc). **Nie używamy `-march=native`** —
na runnerze CI (Ampere) dałby nieprawidłowe tunning i binarkę niekompatybilną z Pi.
`-mcpu=cortex-a76` jest jednoznaczne i działa zarówno w CI, jak i natywnie na Pi.

---

## 2. Wielowątkowość — rzeczywistość LMMS

> **Ważne:** rdzeń silnika audio LMMS jest z założenia **jednowątkowy** (to decyzja
> architektoniczna projektu — render wylicza się na 1 rdzeniu). Nie da się tego zmienić
> flagami kompilacji.

Co build faktycznie daje pod kątem wielowątkowości i wydajności:

- **`-fopenmp`** — wiele wtyczek (m.in. **ZynAddSubFX**) korzysta z OpenMP; kompilacja
  z OpenMP aktywuje tę ścieżkę.
- **`-O3` + LTO** (`-flto`) — największy realny zysk wydajności jednowątkowej (to
  „jedyny realny skok” dla silnika LMMS).
- **Launcher `lmms-pi`** — ustawia `OMP_NUM_THREADS=4`, `OMP_PROC_BIND=spread`,
  `OMP_PLACES=cores`, by wątki OpenMP rozłożyć po 4 rdzeniach **bez przeciażenia**.

---

## 3. Ochrona przed OOM i przeciążeniem CPU

- **Brak OOM w trakcie budowy:** liczba równoległych zadań kompilacji jest liczona
  z dostępnej pamięci, nie z liczby rdzeni, z budżetem ~2 GB na proces i 2 GB marginesu:
  `JOBS = min(nproc, (RAM_GB−2)/2)`. Na runnerze (16 GB, 4 rdzenie) → `JOBS=4`; na Pi
  (8 GB) przy kompilacji lokalnej → `JOBS=2` (bezpiecznie, nawet z LTO). LTO można
  wyłączyć (`enable_lto=false`), gdy chce się jeszcze bardziej oszczędzić RAM.
- **Brak przeciążenia CPU w runtime:** domyślnym backendem jest **PulseAudio**
  (przez pipewire-pulse), a **nie JACK** — na tym konkretnym Pi z PipeWire backend
  JACK powodował znaną **pętlę ~90% CPU** (hang). JACK można włączyć w workflow,
  ale to opcja ryzykowna.
- **Start:** ładowanie wtyczek LV2 przy starcie trwa kilkadziesiąt sekund przy wysokim
  CPU — to normalne (skan pluginów), nie błąd. Po starcie obciążenie spada.

---

## 4. Uruchomienie buildu (GitHub Actions)

Workflow `.github/workflows/lmms-pi.yml` uruchamia się na **darmowym, natywnym**
runnerze **`ubuntu-24.04-arm`** (4 vCPU / 16 GB, publiczne repo).

1. Wejdź w **Actions** → **Build LMMS (Raspberry Pi 5, Cortex-A76, arm64)**.
2. Kliknij **Run workflow** i wybierz opcje:
   - `lmms_ref` — gałąź/tag LMMS (domyślnie `master`);
   - `audio_backend` — `pulse` (zalecane) | `jack` | `both`;
   - `enable_lto` — LTO włączone (zalecane);
   - `min_plugins` — `LMMS_MINIMAL` (tylko AudioFileProcessor/Kicker/TripleOscillator).
3. Po zakończeniu pobierz artifact **`lmms-pi5-arm64`**:
   - `lmms-pi5-arm64.deb` — paczka do instalacji;
   - `lmms-pi5-arm64.tar.gz` — instalacja ręczna (zalecana dla zgodności z /opt/lmms);
   - `lmms-pi5-arm64.sha256` — sumy kontrolne.

Workflow uruchamia się też automatycznie przy `push` na `main` oraz przy utworzeniu
taga `v*` (wtedy pliki trafiają dodatkowo na **GitHub Release**).

---

## 5. Instalacja na Raspberry Pi (Debian trixie)

### Opcja A — paczka .deb (wymaga nazw pakietów Debian)
```bash
sudo apt install ./lmms-pi5-arm64.deb
# launcher: lmms-pi  (alias: lmms)
lmms-pi
```

### Opcja B — instalacja ręczna z tar (zalecana, wzorzec /opt/lmms)
```bash
sudo mkdir -p /opt/lmms
sudo tar -C /opt/lmms -xzf lmms-pi5-arm64.tar.gz
sudo install -Dm755 scripts/lmms-pi-launcher.sh /usr/local/bin/lmms-pi
sudo ln -sf lmms-pi /usr/local/bin/lmms
lmms-pi
```

> Launcher `lmms-pi` ustawia zmienne runtime (OpenMP, `PIPEWIRE_LATENCY=256/48000`,
> `QT_QPA_PLATFORM=wayland`) i uruchamia `/opt/lmms/bin/lmms`. Możesz nadpisać ścieżkę
> binarki przez `LMMS_BIN`.

---

## 6. Budowa natywnie na Pi (opcjonalnie — maksymalna zgodność)

CI daje identyczny tunning (`-mcpu=cortex-a76`), ale jeśli chcesz zbudować lokalnie:

```bash
sudo apt install build-essential cmake ninja-build pkg-config \
  qt6-base-dev qt6-base-dev-tools qt6-tools-dev qt6-tools-dev-tools qt6-svg-dev \
  libsndfile1-dev libsamplerate0-dev libfftw3-dev libflac-dev libogg-dev libvorbis-dev \
  libmp3lame-dev libpulse-dev libasound2-dev libjack-jackd2-dev libfluidsynth-dev \
  zlib1g-dev libsqlite3-dev libarchive-dev liblilv-dev libsuil-dev libsndio-dev \
  libgl-dev libfltk1.3-dev fluid libgig-dev libsdl2-dev libsoundio-dev \
  portaudio19-dev libstk-dev libx11-dev liblist-moreutils-perl

./scripts/build-lmms-pi.sh          # flagi A76 + OpenMP + LTO, JOBS z RAM
```

Skrypt wykrywa rdzenie i RAM i sam dobiera bezpieczne `JOBS`.

---

## 7. Pliki

| Plik | Rola |
|---|---|
| `.github/workflows/lmms-pi.yml` | CI: runner arm64, zależności, budowa, pakiety .deb/tar, Release |
| `scripts/build-lmms-pi.sh` | Logika buildu: flagi A76, OpenMP, LTO, bezpieczne JOBS |
| `scripts/lmms-pi-launcher.sh` | Launcher runtime (OpenMP, latencja, backend) |
| `README.md` | Niniejsza dokumentacja |

---

## 8. Rozwiązywanie problemów

- **Brak dźwięku / cichy dźwięk** — upewnij się, że PipeWire działa
  (`systemctl --user status pipewire`), a LMMS używa backendu PulseAudio
  (Ustawienia → Audio). Nie wybieraj JACK (ryzyko pętli CPU).
- **Wysokie CPU przy starcie** — to skanowanie wtyczek LV2; odczekaj 30–60 s.
- **OOM** — jeśli kompilujesz lokalnie i zabraknie RAM, ustaw `ENABLE_LTO=0`
  (LTO zwiększa użycie pamięci na etapie linkowania).
- **Błąd zależności .deb na trixie** — nazwy `t64` (`libqt6core6`, `libgig10` itd.)
  są obsługiwane przez pakiety wirtualne; w razie problemów użyj **Opcji B** (tar).
