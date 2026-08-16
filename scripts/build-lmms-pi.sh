#!/usr/bin/env bash
# =============================================================================
# build-lmms-pi.sh — kompilacja LMMS zoptymalizowana pod Raspberry Pi 5
#                    (Broadcom BCM2712, CPU Cortex-A76, aarch64)
#
# DZIAŁA DWÓCH ŚRODOWISKACH:
#   1. GitHub Actions (runner ubuntu-24.04-arm, 4 vCPU / 16 GB, darmowy,
#      publiczne repo)  — CI wywołuje ten skrypt.
#   2. Natywnie NA PI (mocno zalecane dla maksymalnej zgodności z A76):
#        sudo apt install <zależności>   # patrz README
#        ./scripts/build-lmms-pi.sh
#
# Kluczowe założenia optymalizacyjne (patrz README → „Analiza SoC”):
#   • CPU docelowy  : Cortex-A76 = ARMv8.2-A + LSE(atomics) + dotprod + crypto
#                     + fp16 + rcpc + crc32.  Najlepsza flaga = -mcpu=cortex-a76.
#   • WIELOWĄTKOWOŚĆ: LMMS rdzeń audio jest z założenia jednowątkowy (architektura
#                     silnika). Wiele wtyczek (np. ZynAddSubFX) korzysta z OpenMP,
#                     więc dodajemy -fopenmp. Ilość wątków ograniczamy w launcherze
#                     (OMP_NUM_THREADS), by nie przeciażyć 4 rdzeni.
#   • BRAK OOM      : liczba zadań kompilacji jest dobierana z RAM, nie z samych
#                     rdzeni (JOBS = min(nproc, RAM_GB/4)).
#   • BRAK PRZECIĄŻENIA CPU: backend JACK jest domyślnie WYŁĄCZONY, bo na tym
#                     konkretnym RPi5 (PipeWire) powodował pętlę 90% CPU
#                     (znana pułapka). Użyj PulseAudio (przez pipewire-pulse).
#
# Zmienne sterujące (można nadpisać env):
#   LMMS_REF        gałąź/tag LMMS      (domyślnie master)
#   ENABLE_LTO      "1"|"0"  LTO       (domyślnie 1 — największy zysk CPU)
#   AUDIO_BACKEND   pulse|jack|both    (domyślnie pulse — stabilny na Pi)
#   MIN_PLUGINS     "1"|"0"  LMMS_MINIMAL (domyślnie 0 = pełne wtyczki)
#   SRC_DIR         katalog źródeł     (domyślnie src)
#   BUILD_DIR       katalog build      (domyślnie build)
#   INSTALL_DIR     katalog instalacji (domyślnie /tmp/lmms-install)
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------------ domyślne
LMMS_REF="${LMMS_REF:-master}"
ENABLE_LTO="${ENABLE_LTO:-1}"
AUDIO_BACKEND="${AUDIO_BACKEND:-pulse}"          # pulse | jack | both
MIN_PLUGINS="${MIN_PLUGINS:-0}"
SRC_DIR="${SRC_DIR:-src}"
BUILD_DIR="${BUILD_DIR:-build}"
INSTALL_DIR="${INSTALL_DIR:-/tmp/lmms-install}"

# ------------------------------------------- detekcja sprzętu (bezpieczne JOBS)
NPROC="$(nproc 2>/dev/null || echo 1)"
MEM_GB="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)"
# Ochrona przed OOM: budżet ~2 GB RAM na proces kompilacji + 2 GB marginesu.
# JOBS = min(rdzenie, (RAM_GB-2)/2), minimum 1.
SAFE_GB="$(( MEM_GB - 2 ))"; [[ "$SAFE_GB" -lt 1 ]] && SAFE_GB=1
RAM_SAFE="$(( SAFE_GB / 2 ))"; [[ "$RAM_SAFE" -lt 1 ]] && RAM_SAFE=1
JOBS="$(( NPROC < RAM_SAFE ? NPROC : RAM_SAFE ))"; [[ "$JOBS" -lt 1 ]] && JOBS=1
echo "==> Detekcja: nproc=$NPROC, RAM=${MEM_GB}GB → JOBS=$JOBS (ochrona przed OOM)"

# ------------------------------------------- flagi kompilacji dla Cortex-A76
# -mcpu=cortex-a76 ustawia jednocześnie -march=armv8.2-a i -mtune (A76).
# Nie używamy -march=native: na runnerze CI (Ampere) dałby złe tunning.
MARCH="-mcpu=cortex-a76"
BASE_FLAGS="$MARCH -O3 -fopenmp -pipe -fomit-frame-pointer"

LTO_FLAGS=""
if [[ "$ENABLE_LTO" == "1" ]]; then
    LTO_FLAGS="-flto -fno-fat-lto-objects"
    echo "==> LTO: WŁĄCZONE (największy zysk jednowątkowej wydajności)"
else
    echo "==> LTO: wyłączone (szybsza kompilacja, niższe zużycie RAM)"
fi

C_FLAGS="$BASE_FLAGS $LTO_FLAGS"
CXX_FLAGS="$BASE_FLAGS $LTO_FLAGS"
# LTO wymaga też flag linkera
LD_FLAGS=""
[[ "$ENABLE_LTO" == "1" ]] && LD_FLAGS="-flto"

# ------------------------------------------- backend audio (unikaj pętli 90% CPU)
case "$AUDIO_BACKEND" in
    pulse) WANT_JACK=OFF; WANT_PULSEAUDIO=ON;  BACKEND_LABEL="PulseAudio (pipewire-pulse) — STABILNY" ;;
    jack)  WANT_JACK=ON;  WANT_PULSEAUDIO=OFF; BACKEND_LABEL="JACK (uwaga: ryzyko pętli CPU na PipeWire)" ;;
    both)  WANT_JACK=ON;  WANT_PULSEAUDIO=ON;  BACKEND_LABEL="JACK + PulseAudio" ;;
    *)     echo "Błąd: nieznany AUDIO_BACKEND=$AUDIO_BACKEND" >&2; exit 2 ;;
esac
echo "==> Backend audio: $BACKEND_LABEL"

# ------------------------------------------- pobranie źródeł (jeśli trzeba)
if [[ ! -d "$SRC_DIR/.git" ]]; then
    echo "==> Klonowanie LMMS ($LMMS_REF) do $SRC_DIR"
    git clone --depth 1 --branch "$LMMS_REF" https://github.com/LMMS/lmms.git "$SRC_DIR"
else
    echo "==> Użyto istniejących źródeł: $SRC_DIR"
fi

# ------------------------------------------- konfiguracja CMake
echo "==> Konfiguracja CMake (TARGET_UARCH=custom, C/CXX_FLAGS=...)"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DTARGET_UARCH=custom \
    -DCMAKE_C_FLAGS="$C_FLAGS" \
    -DCMAKE_CXX_FLAGS="$CXX_FLAGS" \
    -DCMAKE_C_FLAGS_RELEASE="-DNDEBUG" \
    -DCMAKE_CXX_FLAGS_RELEASE="-DNDEBUG" \
    -DCMAKE_EXE_LINKER_FLAGS="$LD_FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LD_FLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$LD_FLAGS" \
    -DWANT_QT6=ON \
    -DWANT_VST=OFF -DWANT_VST_32=OFF -DWANT_VST_64=OFF \
    -DWANT_ALSA=ON \
    -DWANT_PULSEAUDIO=$WANT_PULSEAUDIO \
    -DWANT_JACK=$WANT_JACK \
    -DWANT_SNDFILE=ON -DWANT_SF2=ON -DWANT_GIG=ON \
    -DWANT_LV2=ON -DWANT_SUIL=ON \
    -DWANT_MP3LAME=ON -DWANT_OGGVORBIS=ON \
    -DWANT_SDL=ON -DWANT_SOUNDIO=ON -DWANT_SNDIO=ON -DWANT_PORTAUDIO=ON \
    -DLMMS_MINIMAL=$MIN_PLUGINS \
    -DCMAKE_INSTALL_PREFIX=/opt/lmms

# ------------------------------------------- budowanie (wielowątkowo, bez OOM)
echo "==> Kompilacja z -j$JOBS (bezpieczne dla RAM)"
cmake --build "$BUILD_DIR" -j"$JOBS"

# ------------------------------------------- instalacja do katalogu staging
echo "==> Instalacja do $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
cmake --install "$BUILD_DIR" --prefix "$INSTALL_DIR"

# ------------------------------------------- podsumowanie
echo
echo "=============================================================="
echo " Zbudowano LMMS dla Raspberry Pi 5 (Cortex-A76, aarch64)"
echo "   Źródła : $SRC_DIR (ref=$LMMS_REF)"
echo "   Instal : $INSTALL_DIR"
echo "   Flagi  : C=$C_FLAGS"
echo "   Backend: $BACKEND_LABEL"
echo "   JOBS   : $JOBS  |  LTO=$ENABLE_LTO  |  MIN_PLUGINS=$MIN_PLUGINS"
echo "=============================================================="
