import argparse
import math
import random
from pathlib import Path

FRAC_BITS = 16
Q_SCALE = 1 << FRAC_BITS
WORD_BITS = 40
WORD_MASK = (1 << WORD_BITS) - 1
RESULT_MAX = 1 << 16
MIN_PCT_GOLDEN_Q16 = 2


def to_q24_16(value: float) -> int:
    return int(round(value * Q_SCALE))


def hex_signed(value: int, bits: int) -> str:
    return f"{value & ((1 << bits) - 1):0{bits // 4}x}"


def golden_exp_q16(diff_q: int) -> int:
    diff_real = diff_q / Q_SCALE
    if diff_real >= 0.0:
        return RESULT_MAX

    value = int(round((2.0 ** diff_real) * RESULT_MAX))
    return max(0, min(RESULT_MAX, value))


def add_case(cases: list[tuple[int, int, int]], max_q: int, diff_q: int) -> None:
    data_q = max_q + diff_q
    golden_q16 = golden_exp_q16(diff_q)
    if golden_q16 < MIN_PCT_GOLDEN_Q16:
        return
    cases.append((data_q, max_q, golden_q16))


def build_cases(random_cases: int, seed: int) -> list[tuple[int, int, int]]:
    rng = random.Random(seed)
    cases: list[tuple[int, int, int]] = []

    # Keep the original simple sweep.
    max_q = to_q24_16(1.0)
    for step in range(15):
        diff_q = -step * (Q_SCALE // 8)
        add_case(cases, max_q, diff_q)

    # Hit every F[15:11] bin with offsets near the left edge, middle, and right edge.
    # Use negative integer parts because LPW_expo sees data_in - max <= 0.
    for integer_part in (-1, -2, -4, -8, -12):
        for frac_seg in range(32):
            for offset in (1, 1024, 2046):
                frac_q = (frac_seg << 11) + offset
                diff_q = (integer_part << FRAC_BITS) + frac_q
                add_case(cases, to_q24_16(16.0), diff_q)

    # Random fixed-point differences. Only remove the 0/1-LSB tail where
    # percentage loss is just a rounding-to-zero artifact.
    for _ in range(random_cases):
        diff_real = -rng.uniform(0.0, 15.4)
        diff_q = to_q24_16(diff_real)
        max_q = to_q24_16(rng.uniform(0.25, 20.0))
        add_case(cases, max_q, diff_q)

    return cases


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Q24.16 LPW_expo testcase vectors.")
    parser.add_argument("--random-cases", type=int, default=2048)
    parser.add_argument("--seed", type=int, default=20260520)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "testcase" / "lpw_expo_vectors.txt",
    )
    args = parser.parse_args()

    cases = build_cases(args.random_cases, args.seed)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    with args.output.open("w", encoding="ascii", newline="\n") as f:
        for data_q, max_q, golden_q16 in cases:
            f.write(
                f"{hex_signed(data_q, WORD_BITS)} "
                f"{hex_signed(max_q, WORD_BITS)} "
                f"{golden_q16:05x}\n"
            )

    print(f"Wrote {len(cases)} LPW_expo cases to {args.output}")


if __name__ == "__main__":
    main()
