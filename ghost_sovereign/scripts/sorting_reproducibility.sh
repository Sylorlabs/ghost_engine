#!/usr/bin/env bash
# Reproducibility probe for sorting_inventor.
set -euo pipefail

N="${1:-20}"
ITERS="${2:-50000}"
BASE_SEED_HEX="${3:-0xC0FFEE0000000000}"

cd "$(dirname "$0")/.."
mkdir -p results/sorting_reproducibility

agg="results/sorting_reproducibility/aggregate.csv"
echo "run,seed_hex,correctness,size,verdict" > "$agg"

pass=0
nonsorter=0
other=0

for i in $(seq 1 "$N"); do
    seed_hex=$(printf "%016X" $(( BASE_SEED_HEX + i * 0x9E3779B97F4A7C15 )) )
    champ="results/sorting_reproducibility/champion_${i}.csv"
    grade="results/sorting_reproducibility/grade_${i}.csv"

    ./zig-out/bin/sorting_inventor --iters="$ITERS" --seed="$seed_hex" \
        --csv="$champ" >/dev/null

    ./zig-out/bin/sorting_reachability_tester --champion="$champ" >/dev/null
    # The tester writes results/sorting_reachability.csv each call;
    # copy the loaded_champion row.
    line=$(grep "^loaded_champion," results/sorting_reachability.csv || true)
    if [ -z "$line" ]; then
        verdict="MISSING"; corr=0; sz=0
    else
        verdict=$(echo "$line" | awk -F',' '{print $NF}')
        corr=$(echo "$line"    | awk -F',' '{print $2}')
        sz=$(echo "$line"      | awk -F',' '{print $3}')
    fi
    cp results/sorting_reachability.csv "$grade"

    echo "$i,$seed_hex,$corr,$sz,$verdict" >> "$agg"
    case "$verdict" in
        *INVENTION*)   pass=$((pass+1)) ;;
        *NON-SORTER*)  nonsorter=$((nonsorter+1)) ;;
        *)             other=$((other+1)) ;;
    esac
    printf "run %2d  seed=%s  size=%s  corr=%s  → %s\n" "$i" "$seed_hex" "$sz" "$corr" "$verdict"
done

echo ""
echo "=== SORTING REPRODUCIBILITY SUMMARY (N=$N) ==="
echo "INVENTION (strict):  $pass / $N"
echo "NON-SORTER:          $nonsorter / $N"
echo "other:               $other / $N"
echo "Aggregate CSV: $agg"
