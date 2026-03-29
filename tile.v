`timescale 1ns/10ps
module tile(clk, rst_n, vecA, vecB, int4_gate, int8_gate, VSQ_gate, tile_done, latch_array, start);        
    input clk;
    input rst_n;
    input [255:0] vecA [0:15];  
    input [255:0] vecB;     
    input int4_gate;
    input int8_gate;
    input VSQ_gate;
    input start;

    input tile_done;
    output reg [23:0] latch_array [0:15][0:15]; //16*(24*16=384)
    
    reg signed [23:0] MAC_result [0:15];
    reg signed [23:0] partial_sum_in [0:15];

    MAC16 MAC_unit (
                .vecA(vecA), 
                .vecB(vecB), 
                .int4_gate(int4_gate), 
                .int8_gate(int8_gate), 
                .VSQ_gate(VSQ_gate), 
                .partial_sum_in(partial_sum_in), 
                .result(MAC_result)
                );

    parameter AD = 16;
    reg [4:0] counter;
    // reg [4:0] counter_next;
    reg signed [23:0] collector [0:15][0:15];

    // prepare partial_sum_in from collector
    integer k;
    always @(*) begin
        for (k = 0; k < 16; k = k + 1) begin
            if (counter == 0) 
                partial_sum_in[k] = 24'd0;
            else 
                partial_sum_in[k] = collector[k][counter-1];
        end
    end

    integer i,j;
    always @(posedge clk or negedge rst_n) begin
        // counter <= counter_next;
        if (!rst_n) begin
            counter <= 0;
            // counter_next <= 0;
            for (i=0; i<16; i=i+1) begin
                for (j=0; j<AD; j=j+1) begin
                    collector[i][j] <= 24'b0;
                end
            end
        end
        else if (tile_done) begin
        // commit result
            for (i=0; i<16; i=i+1)
                for (j=0; j<AD; j=j+1)
                    latch_array[i][j] <= collector[i][j];

            // clear collector for next tile
            for (i=0; i<16; i=i+1)
                for (j=0; j<AD; j=j+1)
                    collector[i][j] <= 24'b0;

            counter <= 0;
        end
        else if (!start) begin
        counter <= 0; 
        end
        else begin
            // advance column (vecA reuse)
            if (counter == AD)
                counter <= 0;
            else
                counter <= counter + 1;
            // normal accumulation
            if (counter != 0) begin
                for (i=0; i<16; i=i+1) begin
                    collector[i][counter-1] <= MAC_result[i];
                    //$display("collector[%0d][%0d] = %0d", i, counter-1, MAC_result[i]);
                end
            end
        end
    end
endmodule