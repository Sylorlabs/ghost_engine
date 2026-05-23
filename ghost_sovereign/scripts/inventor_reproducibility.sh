#!/usr/bin/env bash
# Reproducibility probe for program_synthesis_inventor:
#   Run the inventor N times with different seeds, grade each champion
#   with the reachability tester, aggregate verdicts. Reports invention
#   hit rate — the missing number for "is this an engine or a lucky run."
set -euo pipefail

N="${1:-20}"
ITERS="${2:-8000}"
SEEDS="${3:-128}"
BASE_SEED_HEX="${4:-0xC0FFEE0000000000}"

cd "$(dirname "$0")/.."
mkdir -p results/reproducibility

agg="results/reproducibility/aggregate.csv"
echo "run,seed_hex,verdict,quality_pass,best_bit,reach_bits,reach_depth" > "$agg"

pass=0
nonmixer=0
other=0

for i in $(seq 1 "$N"); do
    seed_hex=$(printf "%016X" $(( BASE_SEED_HEX + i * 0x9E3779B97F4A7C15 )) )
    champ="results/reproducibility/champion_${i}.csv"
    grade="results/reproducibility/grade_${i}.csv"

    ./zig-out/bin/program_synthesis_inventor \
        --iters="$ITERS" --seeds="$SEEDS" --seed="$seed_hex" >/dev/null
    cp results/program_synthesis_champion.csv "$champ"

    ./zig-out/bin/reachability_tester \
        --champion="$champ" --csv="$grade" --quiet >/dev/null

    verdict_line=$(grep "^loaded_champion_csv," "$grade" || true)
    if [ -z "$verdict_line" ]; then
        verdict="MISSING"
        qp="0"; bb="0"; rb="0"; rd="0"
    else
        verdict=$(echo "$verdict_line" | awk -F',' '{print $NF}')
        qp=$(echo "$verdict_line"     | awk -F',' '{print $11}')
        bb=$(echo "$verdict_line"     | awk -F',' '{print $5}')
        rb=$(echo "$verdict_line"     | awk -F',' '{print $12}')
        rd=$(echo "$verdict_line"     | awk -F',' '{print $13}')
    fi

    echo "$i,$seed_hex,$verdict,$qp,$bb,$rb,$rd" >> "$agg"
    case "$verdict" in
        *INVENTION*)  pass=$((pass+1)) ;;
        *NON-MIXER*)  nonmixer=$((nonmixer+1)) ;;
        *)            other=$((other+1)) ;;
    esac
    printf "run %2d  seed=%s  → %s\n" "$i" "$seed_hex" "$verdict"
done

echo ""
echo "=== REPRODUCIBILITY SUMMARY (N=$N) ==="
echo "INVENTION (strict):  $pass / $N"
echo "NON-MIXER:           $nonmixer / $N"
echo "other:               $other / $N"
echo "Aggregate CSV: $agg"
