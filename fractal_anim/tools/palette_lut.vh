	function [23 : 0] palette(input [6 : 0] cnt);
		case(cnt)
			7'd0: palette = 24'h061626;
			7'd1: palette = 24'h0B3548;
			7'd2: palette = 24'h105469;
			7'd3: palette = 24'h17788B;
			7'd4: palette = 24'h209DAC;
			7'd5: palette = 24'h36BBC5;
			7'd6: palette = 24'h52D5DB;
			7'd7: palette = 24'h76E8EA;
			7'd8: palette = 24'hA2F4F2;
			7'd9: palette = 24'hD0F9F2;
			7'd10: palette = 24'hF9F1E4;
			7'd11: palette = 24'hF4A97E;
			7'd12: palette = 24'hD76D28;
			7'd13: palette = 24'h78281C;
			7'd14: palette = 24'h000000;
			default: palette = 24'h000000;
		endcase
	endfunction
