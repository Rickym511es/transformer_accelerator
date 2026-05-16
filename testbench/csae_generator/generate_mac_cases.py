import argparse
import random
from pathlib import Path


MAT_M = 1024
MAT_K = 64
MAT_N = 1024
VL = 16
VS = 32
AD = 16
INT8_MIN = -128
INT8_MAX = 127
INT24_WIDTH = 24


def twos_complement_bits(value: int, width: int) -> str:
    mask = (1 << width) - 1
    return format(value & mask, f"0{width}b")


def pack_int8_vector(values: list[int]) -> str:
    """Pack logical lane 0 into bits [7:0], matching vec[n*8 +: 8]."""

    return "".join(twos_complement_bits(value, 8) for value in reversed(values))


def build_matrix(rows: int, cols: int, rng: random.Random, low: int, high: int) -> list[list[int]]:
    return [[rng.randint(low, high) for _ in range(cols)] for _ in range(rows)]


def multiply(a_matrix: list[list[int]], b_matrix: list[list[int]]) -> list[list[int]]:
    c_matrix = [[0 for _ in range(MAT_N)] for _ in range(MAT_M)]

    for row in range(MAT_M):
        a_row = a_matrix[row]
        c_row = c_matrix[row]
        for k_idx in range(MAT_K):
            a_value = a_row[k_idx]
            b_row = b_matrix[k_idx]
            for col in range(MAT_N):
                c_row[col] += a_value * b_row[col]

    return c_matrix


def write_decimal_matrix(path: Path, matrix: list[list[int]]) -> None:
    with path.open("w", encoding="ascii") as f:
        for row in matrix:
            f.write(" ".join(str(value) for value in row))
            f.write("\n")


def write_tiled_inputs(case_dir: Path, a_matrix: list[list[int]], b_matrix: list[list[int]]) -> None:
    m_tiles = MAT_M // VL
    k_tiles = MAT_K // VS
    n_tiles = MAT_N // AD

    for m_tile in range(m_tiles):
        row_base = m_tile * VL
        for k_tile in range(k_tiles):
            k_base = k_tile * VS
            path = case_dir / f"vecA_tile{m_tile + 1}-{k_tile + 1}.txt"
            with path.open("w", encoding="ascii") as f:
                for row_lane in range(VL):
                    values = a_matrix[row_base + row_lane][k_base:k_base + VS]
                    f.write(pack_int8_vector(values))
                    f.write("\n")

    for n_tile in range(n_tiles):
        col_base = n_tile * AD
        for k_tile in range(k_tiles):
            k_base = k_tile * VS
            path = case_dir / f"vecB_stream{n_tile + 1}-{k_tile + 1}.txt"
            with path.open("w", encoding="ascii") as f:
                for col_lane in range(AD):
                    col = col_base + col_lane
                    values = [b_matrix[k_base + offset][col] for offset in range(VS)]
                    f.write(pack_int8_vector(values))
                    f.write("\n")


def write_tiled_golden(case_dir: Path, c_matrix: list[list[int]]) -> None:
    m_tiles = MAT_M // VL
    n_tiles = MAT_N // AD

    for m_tile in range(m_tiles):
        row_base = m_tile * VL
        for n_tile in range(n_tiles):
            col_base = n_tile * AD
            path = case_dir / f"C_golden_tile{m_tile + 1}-{n_tile + 1}.txt"
            with path.open("w", encoding="ascii") as f:
                for row_lane in range(VL):
                    row = row_base + row_lane
                    for col_lane in range(AD):
                        col = col_base + col_lane
                        f.write(twos_complement_bits(c_matrix[row][col], INT24_WIDTH))
                        f.write("\n")


def generate_case(case_dir: Path, seed: int, low: int, high: int) -> None:
    rng = random.Random(seed)
    case_dir.mkdir(parents=True, exist_ok=True)

    a_matrix = build_matrix(MAT_M, MAT_K, rng, low, high)
    b_matrix = build_matrix(MAT_K, MAT_N, rng, low, high)
    c_matrix = multiply(a_matrix, b_matrix)

    write_decimal_matrix(case_dir / "A.txt", a_matrix)
    write_decimal_matrix(case_dir / "B.txt", b_matrix)
    write_decimal_matrix(case_dir / "C_golden.txt", c_matrix)
    write_tiled_inputs(case_dir, a_matrix, b_matrix)
    write_tiled_golden(case_dir, c_matrix)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate MAC testcases for A(1024x64) * B(64x1024) = C(1024x1024)."
    )
    parser.add_argument("--patterns", type=int, default=1)
    parser.add_argument("--seed", type=int, default=20260515)
    parser.add_argument("--min", dest="value_min", type=int, default=INT8_MIN)
    parser.add_argument("--max", dest="value_max", type=int, default=INT8_MAX)
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "testcase" / "mac",
    )
    args = parser.parse_args()

    if args.value_min < INT8_MIN or args.value_max > INT8_MAX or args.value_min > args.value_max:
        raise ValueError("values must stay inside signed int8 range [-128, 127]")

    for pat_idx in range(args.patterns):
        case_dir = args.out_dir / f"pat{pat_idx}"
        generate_case(case_dir, args.seed + pat_idx, args.value_min, args.value_max)
        print(f"Wrote MAC testcase pat{pat_idx} to {case_dir}")


if __name__ == "__main__":
    main()
