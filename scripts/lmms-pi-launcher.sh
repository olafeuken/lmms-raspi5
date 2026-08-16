#!/usr/bin/env bash
# =============================================================================
# lmms-pi-launcher.sh — uruchamia LMMS zoptymalizowany dla Raspberry Pi 5
#                       (4 rdzenie Cortex-A76, 8 GB RAM)
#
# Kontroluje środowisko uruchomieniowe, aby:
#   • wykorzystać wielowątkowość OpenMP (wtyczki) bez przeciazania 4 rdzeni,
#   • utrzymać niską latencję audio (PipeWire) — 256/48000 jak w setupie LMMS,
#   • uniknąć przeciażenia CPU (brak backendu JACK z pętlą 90%).
#
# Instalacja: ten plik jest instalowany jako /usr/local/bin/lmms-pi
# (workflow/deb umieszczają go automatycznie).
# =============================================================================
set -euo pipefail

# Liczba rdzeni A76 w RPi5 (bez SMT) — przekaż do OpenMP/FFTW.
NCORES="$(nproc 2>/dev/null || echo 4)"
[[ "$NCORES" -gt 4 ]] && NCORES=4          # RPi5 ma dokładnie 4 rdzenie
export OMP_NUM_THREADS="$NCORES"
export OMP_PROC_BIND=spread                 # rozłóż wątki po rdzeniach
export OMP_PLACES=cores
export FFTW_NTHREADS="$NCORES"              # gdyby FFTW z wątkami był użyty

# Latencja audio (PipeWire) — zgodna z profilem LMMS: 256 / 48 kHz.
export PIPEWIRE_LATENCY="${PIPEWIRE_LATENCY:-256/48000}"

# Backend: PulseAudio przez pipewire-pulse (stabilny, bez pętli CPU z JACK).
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"

# Ścieżka do binarnego (domyślnie /opt/lmms/bin/lmms).
LMMS_BIN="${LMMS_BIN:-/opt/lmms/bin/lmms}"

if [[ ! -x "$LMMS_BIN" ]]; then
    echo "Błąd: nie znaleziono $LMMS_BIN" >&2
    echo "Ustaw LMMS_BIN na ścieżkę do binarki LMMS." >&2
    exit 1
fi

exec "$LMMS_BIN" "$@"
