from pathlib import Path

ROWS = 16
TILES = 64
LANES = 16


def score_case(row: int, tile: int, lane: int) -> float:
    """Return the real score used by the softmax testcase."""

    units = (tile * 7 + row * 11 + lane * 13 + (tile // 3) * 5) % 65
    if (tile + row + lane) % 29 == 0:
        units //= 2
    return units / 16.0


def main() -> None:
    scores = [
        [[0.0 for _ in range(LANES)] for _ in range(TILES)]
        for _ in range(ROWS)
    ]
    for row in range(ROWS):
        for tile in range(TILES):
            for lane in range(LANES):
                scores[row][tile][lane] = score_case(row, tile, lane)

    row_max = [
        max(scores[row][tile][lane] for tile in range(TILES) for lane in range(LANES))
        for row in range(ROWS)
    ]
    row_sum = [
        sum(2.0 ** (scores[row][tile][lane] - row_max[row])
            for tile in range(TILES)
            for lane in range(LANES))
        for row in range(ROWS)
    ]

    out_path = Path(__file__).resolve().parent / "testcase" / "ppu_cases.txt"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with out_path.open("w", encoding="ascii") as f:
        for row in range(ROWS):
            for tile in range(TILES):
                for lane in range(LANES):
                    score = scores[row][tile][lane]
                    golden = (2.0 ** (score - row_max[row])) / row_sum[row]
                    f.write(
                        f"{row:d} {tile:d} {lane:d} "
                        f"{score:.12f} {golden:.12f}\n"
                    )

    print(f"Wrote {ROWS * TILES * LANES} PPU cases to {out_path}")


if __name__ == "__main__":
    main()
