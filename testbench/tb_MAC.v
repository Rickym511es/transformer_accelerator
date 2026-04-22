`timescale 1ns/10ps
`define CYCLE       10.0
`define PAT_NUM     10
`define End_CYCLE   1000000

module testbench;
reg clk;
reg rst_n;

reg [255:0] Amem [0:15];
reg [255:0] Bmem [0:15];
reg [255:0] vecB;
reg int4_gate;
reg int8_gate;
reg VSQ_gate;
reg tile_done;
reg [23:0] latch_array [0:15][0:15];
reg start;

tile uut (
    .clk(clk),
    .rst_n(rst_n),
    .vecA(Amem),
    .vecB(vecB),
    .int4_gate(int4_gate),
    .int8_gate(int8_gate),
    .VSQ_gate(VSQ_gate),
    .tile_done(tile_done),
    .latch_array(latch_array),
    .start(start)
);

initial clk = 0;
always #(`CYCLE/2) clk = ~clk;

integer cycle_count;
initial begin
   cycle_count = 0;
   @(negedge clk);
   while (1) begin
      cycle_count = cycle_count + 1;
      @(negedge clk);
   end
end

reg [23:0] golden [0:15][0:15];
integer i, j, fd;
integer p;

integer err;
integer pass;
integer ERR;
reg [256*8-1:0] pathA; //ASCII = 8bits
reg [256*8-1:0] pathB;
reg [256*8-1:0] pathG;

initial begin
    $fsdbDumpfile("tile.fsdb");
    $fsdbDumpvars;
    $fsdbDumpMDA;
end
////////////////
integer step2; // K/VS
integer step3; // N/AD
integer step4; // M/VL
////////////////
initial begin
    err = 0;
    pass = 0;
    
    int4_gate = 0;
    int8_gate = 1;
    VSQ_gate  = 0;
    vecB      = 0;
    tile_done = 0;
    rst_n     = 0;
    start     = 0;

    for (p = 0; p < `PAT_NUM; p = p + 1) begin
        $display("================================");
        $display("Start pat %0d", p);

        rst_n = 0;
        @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        start = 1;
        
        for (step4 = 1 ; step4 < 17; step4 = step4 + 1) begin
            for (step3 = 1; step3 < 17; step3 = step3 + 1) begin
                
                rst_n = 0;
                @(posedge clk);
                rst_n = 1;
                start = 1;

                $sformat(pathG, "MMpattern(stage4+)/pat%0d/C_golden_tile%0d-%0d.txt", p, step4, step3); 
                for (step2 = 1; step2 < 17; step2 = step2 + 1) begin
                    $sformat(pathA, "MMpattern(stage4+)/pat%0d/vecA_tile%0d-%0d.txt", p, step4, step2);
                    $sformat(pathB, "MMpattern(stage4+)/pat%0d/vecB_stream%0d-%0d.txt", p, step3, step2);
                    $readmemb(pathA, Amem);
                    $readmemb(pathB, Bmem);
                    $readmemb(pathG, golden);

                    for (i = 0; i < 16; i = i + 1) begin
                        vecB <= Bmem[i];
                        @(posedge clk);
                    end
                    @(posedge clk);
                end
                start <= 0;
                tile_done <= 1'b1;
                @(posedge clk);
                tile_done <= 1'b0;
                @(posedge clk);

                // ---------- compare ----------
                ERR = 0;
                for (i = 0; i < 16; i = i + 1) begin
                    for (j = 0; j < 16; j = j + 1) begin
                        if ($signed(latch_array[i][j]) !== golden[i][j]) 
                            ERR = 1;
                    end
                end
                if (ERR == 0) begin
                    pass = pass + 1;
                    $display("Pattern %0d - tile%0d-%0d: PASS", p, step4, step3);
                end
                else begin
                    err = err + 1;
                    $display("Pattern %0d- tile%0d-%0d: FAIL", p, step4, step3);
                end
            end
        end

    end

    if (err == 0) begin
        $display("Congratulations! All data have been generated successfully!\n");
        $display("Total cost time: %10.2f ns", cycle_count*(`CYCLE));
        $display("-------------------------PASS------------------------\n");
    end
    else begin
        $display("Final Simulation Result as below: \n");         
        $display("-----------------------------------------------------\n");
        $display("Pass:   %3d \n", pass);
        $display("Error:  %3d \n", err);
        $display("-----------------------------------------------------\n");
    end

    $finish;
end

initial begin
	#(`End_CYCLE*(`CYCLE));
	$display("-----------------------------------------------------\n");
	$display("Error!!! There is something wrong with your code ...!\n");
 	$display("------The test result is .....FAIL ------------------\n");
 	$display("-----------------------------------------------------\n");
 	$finish;
end
endmodule