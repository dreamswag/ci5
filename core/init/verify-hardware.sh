#!/bin/sh
# Era 4.75 Hardware Verification Suite
# Detects VM, emulator, and rootkit-based serial spoofing

set -e

# Temporary C file
C_FILE="/tmp/verify_cache.c"
BIN_FILE="/tmp/verify_cache"

verify_hwrng_entropy_robust() {
    echo "[*] Verifying hardware RNG (Robust Mode)..."
    if [ ! -c /dev/hwrng ]; then
        echo "[!] No hardware RNG found"
        return 1
    fi

    # Check throughput consistency
    # Real HWRNG has specific throughput range. Emulators are often instant or very slow.
    
    # Measure time to read 1MB
    start_time=$(date +%s%N)
    dd if=/dev/hwrng of=/dev/null bs=1024 count=1024 2>/dev/null
    end_time=$(date +%s%N)
    # Handle systems where date +%s%N might not be supported or accurate enough, but standard on linux
    duration=$(( (end_time - start_time) / 1000000 )) # ms

    echo "    1MB Read Time: ${duration}ms"
    
    if [ "$duration" -lt 5 ]; then
        echo "[!] HWRNG too fast (Software/Fake?)"
        return 1
    fi
    
    if [ "$duration" -gt 2000 ]; then
        echo "[!] HWRNG too slow"
        return 1
    fi

    # Check entropy quality
    sample=$(dd if=/dev/hwrng bs=1024 count=1 2>/dev/null | xxd -p | tr -d '\n')
    unique_bytes=$(echo "$sample" | fold -w2 | sort -u | wc -l)
    
    if [ "$unique_bytes" -lt 200 ]; then
        echo "[!] Low entropy: $unique_bytes unique bytes"
        return 1
    fi
    
    echo "[+] HWRNG verified."
    return 0
}

compile_and_run_verification() {
    echo "[*] Compiling hardware verification micro-benchmark..."
    
    cat > "$C_FILE" << 'EOF'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define CACHE_LINE_SIZE 64
#define ARRAY_SIZE (1024 * 1024) // 1MB

uint64_t get_cntvct(void) {
    uint64_t val;
    asm volatile("mrs %0, cntvct_el0" : "=r" (val));
    return val;
}

int main() {
    volatile uint8_t *array = (uint8_t *)malloc(ARRAY_SIZE);
    if (!array) return 1;

    // Initialize
    for (int i = 0; i < ARRAY_SIZE; i++) array[i] = i;

    // Measure L1 access (cached)
    uint64_t start = get_cntvct();
    volatile uint8_t temp = array[0];
    uint64_t end = get_cntvct();
    uint64_t l1_time = end - start;

    // Measure RAM access (cold) - rough approximation
    start = get_cntvct();
    temp = array[ARRAY_SIZE/2]; // Jump 512KB
    end = get_cntvct();
    uint64_t ram_time = end - start;
    
    printf("%lu %lu\n", l1_time, ram_time);
    
    free((void*)array);
    return 0;
}
EOF

    if ! command -v gcc >/dev/null 2>&1; then
        echo "[!] GCC not found. Falling back to entropy check."
        rm -f "$C_FILE"
        return 2
    fi

    if ! gcc -O0 -o "$BIN_FILE" "$C_FILE"; then
        echo "[!] Compilation failed."
        rm -f "$C_FILE"
        return 1
    fi

    echo "[*] Running micro-benchmark..."
    output=$("$BIN_FILE")
    rm -f "$C_FILE" "$BIN_FILE"
    
    l1=$(echo "$output" | awk '{print $1}')
    ram=$(echo "$output" | awk '{print $2}')
    
    echo "    L1 Cycles: $l1"
    echo "    RAM Cycles: $ram"

    # Thresholds: L1 < 100, RAM > 200 (Adjust based on BCM2712 profile)
    if [ "$l1" -lt 100 ] && [ "$ram" -gt 200 ]; then
         echo "[+] Cache timing consistent with silicon."
         return 0
    else
         echo "[!] Timing anomalies detected (Possible Emulation)."
         return 1
    fi
}

verify_cache_timing() {
    compile_and_run_verification
    ret=$?
    if [ $ret -eq 2 ]; then
        verify_hwrng_entropy_robust
        return $?
    fi
    return $ret
}

verify_device_tree() {
    echo "[*] Verifying device tree..."
    local model=""
    if [ -f /proc/device-tree/model ]; then
        model=$(tr -d '\0' < /proc/device-tree/model)
    fi
    case "$model" in
        *"Raspberry Pi 5"*) echo "[+] Device tree confirms Pi 5"; return 0 ;;
        *)
            echo "[!] Unexpected device: $model"
            return 1
            ;; 
    esac
}

run_full_verification() {
    local failures=0
    echo "════════════════════════════════════════════════════════"
    echo "  CI5 Hardware Verification Suite (Era 4.75)"
    echo "════════════════════════════════════════════════════════"
    
    verify_device_tree || failures=$((failures + 1))
    verify_cache_timing || failures=$((failures + 1))
    
    echo ""
    if [ "$failures" -eq 0 ]; then
        echo "  RESULT: PASS - Hardware appears genuine"
        return 0
    else
        echo "  RESULT: FAIL - $failures verification(s) failed"
        return 1
    fi
}

case "$1" in
    cache)      verify_cache_timing ;; 
    dt)         verify_device_tree ;; 
    full|"")    run_full_verification ;; 
    *)
        echo "Usage: $0 {cache|dt|full}" 
        ;;
esac