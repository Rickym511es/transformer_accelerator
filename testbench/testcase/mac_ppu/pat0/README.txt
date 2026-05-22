MAC -> PPU testcase
Q shape: 1024x64, file: query_int8.txt
K^T source shape: 64x1024, file: key_int8.txt
MAC score shape: 1024x1024, file: mac_score_int24.txt
Golden file: base2_softmax_quant.txt
Golden formula: softmax = 2^(score-max)/sum(2^(score-max))
Quant formula: q = round((softmax/max_softmax) * 127)
score = MAC_result / 8.0
External query/key scales are intentionally ignored.
