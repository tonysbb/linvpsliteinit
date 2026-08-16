#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

load_script() {
    sed \
        -e '/^start_logging$/d' \
        -e '/^trap cleanup_logging EXIT$/d' \
        -e '/started\. Log:/d' \
        -e '${/^main\( "\$@"\)\{0,1\}$/d;}' \
        "$1"
}

assert_eq() {
    expected=$1 actual=$2 label=$3
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL %s: expected=%s actual=%s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
    printf 'PASS %s\n' "$label"
}

run_policy_tests() {
    script=$1
    tmp=${TMPDIR:-/tmp}/linvps-policy-$$.sh
    load_script "$script" > "$tmp"
    # shellcheck disable=SC1090
    . "$tmp"
    rm -f "$tmp"

    assert_eq 128 "$(normalize_ram_mib 131072)" "128MiB unchanged"
    assert_eq 115 "$(normalize_ram_mib 117964)" "just below 90 percent stays below 128MiB"
    assert_eq 128 "$(normalize_ram_mib 117965)" "90 percent threshold normalizes to 128MiB"
    assert_eq 256 "$(normalize_ram_mib 250000)" "244MiB normalizes to 256"
    assert_eq 1024 "$(normalize_ram_mib 997104)" "973MiB normalizes to 1024"
    assert_eq 2048 "$(normalize_ram_mib 2027020)" "1979MiB normalizes to 2048"
    assert_eq 6144 "$(normalize_ram_mib 6291456)" "6GiB remains 6GiB"
    assert_eq 12288 "$(normalize_ram_mib 12582912)" "12GiB remains 12GiB"
    assert_eq 20480 "$(normalize_ram_mib 20971520)" "20GiB remains 20GiB"

    assert_eq 64 "$(recommend_zram_mib 128)" "128MiB RAM zram"
    assert_eq 128 "$(recommend_zram_mib 256)" "256MiB RAM zram"
    assert_eq 512 "$(recommend_zram_mib 1024)" "1GiB RAM zram"
    assert_eq 1024 "$(recommend_zram_mib 2048)" "2GiB RAM zram"
    assert_eq 4096 "$(recommend_zram_mib 8192)" "8GiB RAM zram cap"
    assert_eq 4096 "$(recommend_zram_mib 20480)" "20GiB RAM zram cap"

    assert_eq 256 "$(recommend_disk_swap_mib 128)" "128MiB disk swap"
    assert_eq 2048 "$(recommend_disk_swap_mib 1024)" "1GiB disk swap"
    assert_eq 2048 "$(recommend_disk_swap_mib 2048)" "2GiB disk swap"
    assert_eq 4096 "$(recommend_disk_swap_mib 4096)" "4GiB disk swap"
    assert_eq 4096 "$(recommend_disk_swap_mib 8192)" "8GiB boundary disk swap"
    assert_eq 4096 "$(recommend_disk_swap_mib 20480)" "20GiB disk swap"

    swaps=${TMPDIR:-/tmp}/linvps-swaps-$$
    cat > "$swaps" <<'EOF'
Filename Type Size Used Priority
/dev/zram0 partition 524284 1024 100
/swapfile_by_script file 1572860 2048 -2
/dev/vdb1 partition 262140 0 -3
EOF
    PROC_SWAPS_PATH=$swaps
    export PROC_SWAPS_PATH
    assert_eq 512 "$(active_zram_swap_mib)" "zram swap classified"
    assert_eq 1792 "$(active_disk_swap_mib)" "disk swap excludes zram"
    rm -f "$swaps"
}

run_policy_tests "$ROOT/vps_init.sh"
run_policy_tests "$ROOT/add_components.sh"
printf 'ALL POLICY TESTS PASS\n'
