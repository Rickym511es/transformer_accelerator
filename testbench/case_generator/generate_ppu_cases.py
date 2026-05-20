import argparse
import math
import random
from pathlib import Path

ROWS = 16
TILES = 64
LANES = 16


def clamp(value: float, low: float = 0.0, high: float = 4.0) -> float:
    return max(low, min(high, value))


def build_scores(rows: int, tiles: int, lanes: int) -> list[list[list[float]]]:
    """Build small nonnegative score cases for softmax accuracy checks.

    These are not meant to mimic the full accelerator stream. They are compact
    softmax-focused cases: uniform, ramps, peaked rows, and fixed-seed
    attention-like score distributions.
    """

    rng = random.Random(20260506)
    scores = [[[0.0 for _ in range(lanes)] for _ in range(tiles)] for _ in range(rows)]
    n = tiles * lanes

    for row in range(rows):
        for tile in range(tiles):
            for lane in range(lanes):
                pos = tile * lanes + lane

                if row == 0:
                    score = 0.0
                elif row == 1:
                    score = clamp(1.0 + 0.20 * rng.gauss(0.0, 1.0))
                elif row == 2:
                    score = clamp(1.0 + 0.55 * rng.gauss(0.0, 1.0))
                elif row == 3:
                    score = clamp(1.2 + 0.90 * rng.gauss(0.0, 1.0))
                elif row == 4:
                    score = 4.0 * pos / (n - 1)
                elif row == 5:
                    score = 4.0 if pos == n // 2 else clamp(0.6 + 0.15 * rng.gauss(0.0, 1.0))
                elif row == 6:
                    score = 3.5 if pos in (n // 3, (2 * n) // 3) else clamp(0.8 + 0.2 * rng.gauss(0.0, 1.0))
                elif row == 7:
                    score = clamp(2.0 + math.sin(pos * 0.55) + 0.15 * rng.gauss(0.0, 1.0))
                else:
                    score = clamp(1.0 + 0.70 * rng.gauss(0.0, 1.0))

                scores[row][tile][lane] = score

    return scores


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate softmax-only PPU testcase.")
    parser.add_argument("--rows", type=int, default=ROWS)
    parser.add_argument("--tiles", type=int, default=TILES)
    parser.add_argument("--lanes", type=int, default=LANES)
    args = parser.parse_args()

    scores = build_scores(args.rows, args.tiles, args.lanes)

    row_max = [
        max(scores[row][tile][lane] for tile in range(args.tiles) for lane in range(args.lanes))
        for row in range(args.rows)
    ]
    row_sum_e = [
        sum(math.exp(scores[row][tile][lane] - row_max[row])
            for tile in range(args.tiles)
            for lane in range(args.lanes))
        for row in range(args.rows)
    ]
    row_sum_2 = [
        sum(2.0 ** (scores[row][tile][lane] - row_max[row])
            for tile in range(args.tiles)
            for lane in range(args.lanes))
        for row in range(args.rows)
    ]

    out_path = Path(__file__).resolve().parent / "testcase" / "softmax_cases.txt"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with out_path.open("w", encoding="ascii") as f:
        for row in range(args.rows):
            for tile in range(args.tiles):
                for lane in range(args.lanes):
                    score = scores[row][tile][lane]
                    golden_e = math.exp(score - row_max[row]) / row_sum_e[row]
                    golden_2 = (2.0 ** (score - row_max[row])) / row_sum_2[row]
                    f.write(
                        f"{row:d} {tile:d} {lane:d} "
                        f"{score:.12f} {golden_e:.12f} {golden_2:.12f}\n"
                    )

    quant_out_path = Path(__file__).resolve().parent / "testcase" / "ppu_quant_cases.txt"
    with quant_out_path.open("w", encoding="ascii") as f:
        for row in range(args.rows):
            row_max_2 = max(
                (2.0 ** (scores[row][tile][lane] - row_max[row])) / row_sum_2[row]
                for tile in range(args.tiles)
                for lane in range(args.lanes)
            )
            for tile in range(args.tiles):
                for lane in range(args.lanes):
                    score = scores[row][tile][lane]
                    golden_2 = (2.0 ** (score - row_max[row])) / row_sum_2[row]
                    golden_quant = math.floor(golden_2 / row_max_2 * 127.0 + 0.5)
                    golden_quant = max(0, min(127, golden_quant))
                    f.write(
                        f"{row:d} {tile:d} {lane:d} "
                        f"{score:.12f} {golden_quant:d}\n"
                    )

    print(f"Wrote {args.rows * args.tiles * args.lanes} softmax cases to {out_path}")
    print(f"Wrote {args.rows * args.tiles * args.lanes} PPU quant cases to {quant_out_path}")


if __name__ == "__main__":
    main()
