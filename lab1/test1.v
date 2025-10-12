
module test1 (
clk,
rstn,
inss,
outss,

//tm,
//si,
//so,
se
);
// input tm;
input se;
//input si;
//output so;

input clk,rstn;
input [7:0] inss;
output [7:0] outss;


reg [1023:0] ddreg;

always @( posedge clk ) 
if (rstn==1'b0)
 ddreg <= 1024'b0;
else
 begin
  ddreg[7:0] <= inss;
  ddreg [1023:8] <= ddreg[1015:0] ;
 end

assign outss = ddreg [1023:1016];

endmodule

