import argparse
import math
from pathlib import Path


MAT_M = 1024
MAT_K = 64
MAT_N = 1024
VL = 16
AD = 16
INT8_MIN = -128
INT8_MAX = 127


def pos_mod(value: int, divisor: int) -> int:
    return value % divisor


def query_value(row: int, k_idx: int) -> int:
    raw = pos_mod((row * 17) + (k_idx * 31) + (row * k_idx * 3) + (row // VL), 3)
    return raw - 1


def key_value(k_idx: int, col: int) -> int:
    raw = pos_mod((k_idx * 19) + (col * 23) + (k_idx * col * 5) + (col // AD), 3)
    return raw - 1


def write_matrix(path: Path, matrix: list[list[int]]) -> None:
    with path.open("w", encoding="ascii") as f:
        for row in matrix:
            f.write(" ".join(str(value) for value in row))
            f.write("\n")


def dot_product(query_row: list[int], key_matrix: list[list[int]], col: int) -> int:
    acc = 0
    for k_idx, query in enumerate(query_row):
        acc += query * key_matrix[k_idx][col]
    return acc


def build_base2_quant_row(scores: list[int], score_divisor: float) -> list[int]:
    real_scores = [score / score_divisor for score in scores]
    row_max = max(real_scores)
    exp_values = [2.0 ** (score - row_max) for score in real_scores]
    exp_sum = sum(exp_values)
    max_probability = 1.0 / exp_sum

    quantized = []
    for exp_value in exp_values:
        probability = exp_value / exp_sum
        quant = math.floor((probability / max_probability) * 127.0 + 0.5)
        quantized.append(max(0, min(127, quant)))
    return quantized


def generate_case(case_dir: Path, score_divisor: float) -> None:
    case_dir.mkdir(parents=True, exist_ok=True)

    query = [[query_value(row, k_idx) for k_idx in range(MAT_K)] for row in range(MAT_M)]
    key = [[key_value(k_idx, col) for col in range(MAT_N)] for k_idx in range(MAT_K)]

    write_matrix(case_dir / "query_int8.txt", query)
    write_matrix(case_dir / "key_int8.txt", key)

    mac_scores = []
    for row in range(MAT_M):
        mac_scores.append([dot_product(query[row], key, col) for col in range(MAT_N)])

    write_matrix(case_dir / "mac_score_int24.txt", mac_scores)

    with (case_dir / "base2_softmax_quant.txt").open("w", encoding="ascii") as f:
        for row in range(MAT_M):
            scores = mac_scores[row]
            quantized = build_base2_quant_row(scores, score_divisor)
            f.write(" ".join(str(value) for value in quantized))
            f.write("\n")

    with (case_dir / "README.txt").open("w", encoding="ascii") as f:
        f.write("MAC -> PPU testcase\n")
        f.write(f"Q shape: {MAT_M}x{MAT_K}, file: query_int8.txt\n")
        f.write(f"K^T source shape: {MAT_K}x{MAT_N}, file: key_int8.txt\n")
        f.write(f"MAC score shape: {MAT_M}x{MAT_N}, file: mac_score_int24.txt\n")
        f.write("Golden file: base2_softmax_quant.txt\n")
        f.write("Golden formula: softmax = 2^(score-max)/sum(2^(score-max))\n")
        f.write("Quant formula: q = round((softmax/max_softmax) * 127)\n")
        f.write(f"score = MAC_result / {score_divisor}\n")
        f.write("External query/key scales are intentionally ignored.\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate Q/K int8 matrices and base-2 softmax quant golden for MAC -> PPU."
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "testcase" / "mac_ppu" / "pat0",
    )
    parser.add_argument(
        "--score-divisor",
        type=float,
        default=8.0,
        help="PPU score divisor. PPU.v currently maps MAC_result to Q24.16 as MAC/8.",
    )
    args = parser.parse_args()

    generate_case(args.out_dir, args.score_divisor)
    print(f"Wrote MAC -> PPU testcase to {args.out_dir}")


if __name__ == "__main__":
    main()
