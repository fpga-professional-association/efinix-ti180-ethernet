// hw_tcp_sink.v - hardware TCP/IP endpoint on the TSEMAC 8-bit AXI stream.
//
// Terminates a single TCP connection (iperf-style sink) entirely in fabric:
// ARP reply, ICMP echo, TCP handshake / cumulative ACK / FIN, with the TCP
// payload discarded at line rate. TCP checksum on TX is left zero for the
// MacTxLso offload stage (same contract lwIP used with CHECKSUM_GEN_TCP=0);
// IP and ICMP checksums are computed here (lwIP had CHECKSUM_GEN_IP/ICMP=1).
//
// RX stream enters in the rgmii_rxc domain and crosses into io_tseClk via a
// gray-pointer async FIFO; parser, TCP state and TX generator all run in the
// io_tseClk (tx) domain. 8 bit x 125 MHz = 1 Gbps, so nothing here can be
// the bottleneck.

module hw_tcp_sink #(
    parameter [47:0] LOCAL_MAC  = 48'h001122334441,
    parameter [31:0] LOCAL_IP   = {8'd192, 8'd168, 8'd1, 8'd55},
    parameter [15:0] LOCAL_PORT = 16'd5001
)(
    // RX stream from MAC (rgmii_rxc domain)
    input  wire        rx_clk,
    input  wire        rx_rst,
    input  wire        rx_tvalid,
    input  wire [7:0]  rx_tdata,
    input  wire        rx_tlast,
    output wire        rx_tready,
    // TX stream to MAC (io_tseClk domain)
    input  wire        tx_clk,
    input  wire        tx_rst,
    output reg         tx_tvalid,
    output reg  [7:0]  tx_tdata,
    output reg         tx_tlast,
    input  wire        tx_tready,
    // debug (tx_clk domain)
    output reg  [31:0] dbg_rx_frames,
    output reg  [31:0] dbg_tcp_bytes,
    output reg  [3:0]  dbg_state
);

// =========================================================================
// Async FIFO: 9 bits ({tlast, tdata}) x 512, rgmii_rxc -> io_tseClk
// =========================================================================
reg  [8:0] fifo_mem [0:511];
reg  [9:0] wptr_bin, rptr_bin;
reg  [9:0] wptr_gray, rptr_gray;
reg  [9:0] wptr_gray_m, wptr_gray_s;   // synced into rx of tx domain
reg  [9:0] rptr_gray_m, rptr_gray_s;   // synced into rx domain

wire [9:0] wptr_bin_n = wptr_bin + 10'd1;
wire       fifo_full  = (wptr_gray == {~rptr_gray_s[9:8], rptr_gray_s[7:0]});
assign     rx_tready  = !fifo_full;

always @(posedge rx_clk) begin
    if (rx_rst) begin
        wptr_bin  <= 10'd0;
        wptr_gray <= 10'd0;
        rptr_gray_m <= 10'd0;
        rptr_gray_s <= 10'd0;
    end else begin
        rptr_gray_m <= rptr_gray;
        rptr_gray_s <= rptr_gray_m;
        if (rx_tvalid && !fifo_full) begin
            fifo_mem[wptr_bin[8:0]] <= {rx_tlast, rx_tdata};
            wptr_bin  <= wptr_bin_n;
            wptr_gray <= wptr_bin_n ^ (wptr_bin_n >> 1);
        end
    end
end

// First-word-fall-through read side: BRAM synchronous read into fifo_q.
wire       fifo_empty = (rptr_gray == wptr_gray_s);
reg        fifo_rd;                    // parser asserts to consume one byte
reg  [8:0] fifo_q;
reg        fifo_q_v;
wire       fifo_consume = fifo_rd && fifo_q_v;
wire       fifo_fetch   = (!fifo_q_v || fifo_consume) && !fifo_empty;
wire [9:0] rptr_bin_n = rptr_bin + 10'd1;

always @(posedge tx_clk) begin
    if (tx_rst) begin
        rptr_bin  <= 10'd0;
        rptr_gray <= 10'd0;
        wptr_gray_m <= 10'd0;
        wptr_gray_s <= 10'd0;
        fifo_q_v  <= 1'b0;
    end else begin
        wptr_gray_m <= wptr_gray;
        wptr_gray_s <= wptr_gray_m;
        if (fifo_fetch) begin
            fifo_q    <= fifo_mem[rptr_bin[8:0]];
            rptr_bin  <= rptr_bin_n;
            rptr_gray <= rptr_bin_n ^ (rptr_bin_n >> 1);
            fifo_q_v  <= 1'b1;
        end else if (fifo_consume) begin
            fifo_q_v  <= 1'b0;
        end
    end
end

wire [7:0] pb      = fifo_q[7:0];      // parser byte
wire       pb_last = fifo_q[8];
wire       pb_v    = fifo_q_v;

// =========================================================================
// Frame parser (tx_clk domain)
// =========================================================================
localparam P_STREAM = 1'd0, P_FINAL = 1'd1;
reg         pstate;
reg  [10:0] idx;                       // byte index within frame
reg  [3:0]  fin_step;

// captured fields
reg  [47:0] r_da, r_sa;
reg  [15:0] r_ethtype;
reg  [5:0]  r_ihl_bytes;
reg  [15:0] r_iplen;
reg  [7:0]  r_proto;
reg  [31:0] r_sip, r_dip;
reg  [15:0] r_sport, r_dport;
reg  [31:0] r_seq, r_ackno;
reg  [7:0]  r_doff_bytes;
reg  [7:0]  r_flags;
reg  [31:0] tcp_sum;                   // ones-complement accumulator
reg  [15:0] r_arp_oper;
reg  [47:0] r_arp_sha;
reg  [31:0] r_arp_spa, r_arp_tpa;
reg  [7:0]  r_icmp_type;
reg  [15:0] r_icmp_csum;
reg         r_truncated;

wire [10:0] ip_idx = idx - 11'd14;                       // index into IP hdr
wire [10:0] l4_idx = idx - 11'd14 - {5'd0, r_ihl_bytes}; // index into L4
wire [15:0] l4_len = r_iplen - {10'd0, r_ihl_bytes};     // TCP/ICMP length
wire        is_ip  = (r_ethtype == 16'h0800);
wire        is_arp = (r_ethtype == 16'h0806);
wire        da_ok  = (r_da == LOCAL_MAC) || (r_da == 48'hFFFFFFFFFFFF);

// ICMP echo payload buffer (single outstanding request)
reg  [7:0]  echo_ram [0:2047];
reg         echo_busy;                 // reply latched, TX not done yet
reg  [15:0] echo_len;
reg  [31:0] echo_ip;
reg  [47:0] echo_mac;
reg  [15:0] echo_csum;

// =========================================================================
// TCP connection state (tx_clk domain)
// =========================================================================
localparam C_LISTEN = 2'd0, C_SYNR = 2'd1, C_EST = 2'd2, C_LASTACK = 2'd3;
reg  [1:0]  conn;
reg  [47:0] peer_mac;
reg  [31:0] peer_ip;
reg  [15:0] peer_port;
reg  [31:0] rcv_nxt, snd_nxt, iss_r;
reg  [31:0] iss_ctr;                   // free-running: initial seq numbers
reg  [31:0] idle_ctr;                  // connection idle timeout

// TX requests
reg         req_synack, req_finack, ack_pending;
reg         arp_pending;
reg  [47:0] arp_tha;
reg  [31:0] arp_tpa;
reg  [31:0] finack_seq;

wire [15:0] payload_len = l4_len - {8'd0, r_doff_bytes};

// parser decisions at end of frame
wire fr_tcp_ok  = is_ip && da_ok && (r_dip == LOCAL_IP) && (r_proto == 8'd6)
                  && !r_truncated;
wire fr_icmp_ok = is_ip && da_ok && (r_dip == LOCAL_IP) && (r_proto == 8'd1)
                  && (r_icmp_type == 8'd8) && !r_truncated && !echo_busy;
wire fr_arp_ok  = is_arp && da_ok && (r_arp_oper == 16'd1)
                  && (r_arp_tpa == LOCAL_IP);
wire peer_match = (r_sip == peer_ip) && (r_sport == peer_port);

// fold helper for checksum finalize
reg  [31:0] sum_fold;

integer i;
always @(posedge tx_clk) begin
    if (tx_rst) begin
        pstate      <= P_STREAM;
        idx         <= 11'd0;
        fin_step    <= 4'd0;
        conn        <= C_LISTEN;
        req_synack  <= 1'b0;
        req_finack  <= 1'b0;
        ack_pending <= 1'b0;
        arp_pending <= 1'b0;
        echo_busy   <= 1'b0;
        iss_ctr     <= 32'd0;
        idle_ctr    <= 32'd0;
        r_truncated <= 1'b0;
        dbg_rx_frames <= 32'd0;
        dbg_tcp_bytes <= 32'd0;
    end else begin
        iss_ctr <= iss_ctr + 32'h9E3779B9;

        // connection idle timeout: ~17 s @125 MHz back to LISTEN
        if (conn != C_LISTEN) begin
            idle_ctr <= idle_ctr + 32'd1;
            if (idle_ctr[31]) begin
                conn     <= C_LISTEN;
                idle_ctr <= 32'd0;
            end
        end

        // request clears driven by TX FSM (see below via clr_* pulses)
        if (clr_synack)  req_synack  <= 1'b0;
        if (clr_finack)  req_finack  <= 1'b0;
        if (clr_ack)     ack_pending <= 1'b0;
        if (clr_arp)     arp_pending <= 1'b0;
        if (clr_echo)    echo_busy   <= 1'b0;

        case (pstate)
        P_STREAM: if (pb_v) begin
            idx <= idx + 11'd1;

            // ---- L2 ----
            if (idx <= 11'd5)                     r_da <= {r_da[39:0], pb};
            else if (idx <= 11'd11)               r_sa <= {r_sa[39:0], pb};
            else if (idx == 11'd12)               r_ethtype[15:8] <= pb;
            else if (idx == 11'd13) begin
                r_ethtype[7:0] <= pb;
                r_truncated    <= 1'b0;
                tcp_sum        <= 32'd0;
            end
            // ---- ARP ----
            else if (r_ethtype == 16'h0806) begin
                case (idx)
                11'd20: r_arp_oper[15:8] <= pb;
                11'd21: r_arp_oper[7:0]  <= pb;
                default: ;
                endcase
                if (idx >= 11'd22 && idx <= 11'd27)
                    r_arp_sha <= {r_arp_sha[39:0], pb};
                if (idx >= 11'd28 && idx <= 11'd31)
                    r_arp_spa <= {r_arp_spa[23:0], pb};
                if (idx >= 11'd38 && idx <= 11'd41)
                    r_arp_tpa <= {r_arp_tpa[23:0], pb};
            end
            // ---- IPv4 ----
            else if (r_ethtype == 16'h0800) begin
                if (idx == 11'd14) begin
                    r_ihl_bytes <= {pb[3:0], 2'b00};   // IHL * 4
                    if (pb[7:4] != 4'd4) r_truncated <= 1'b1; // not v4: kill
                end
                else if (idx == 11'd16) r_iplen[15:8] <= pb;
                else if (idx == 11'd17) r_iplen[7:0]  <= pb;
                else if (idx == 11'd23) r_proto       <= pb;
                else if (idx >= 11'd26 && idx <= 11'd29)
                    r_sip <= {r_sip[23:0], pb};
                else if (idx >= 11'd30 && idx <= 11'd33)
                    r_dip <= {r_dip[23:0], pb};

                // ---- L4 (past IP header of any IHL) ----
                if (idx >= (11'd14 + {5'd0, r_ihl_bytes}) && idx >= 11'd34) begin
                    if (r_proto == 8'd6) begin
                        case (l4_idx)
                        11'd0:  r_sport[15:8] <= pb;
                        11'd1:  r_sport[7:0]  <= pb;
                        11'd2:  r_dport[15:8] <= pb;
                        11'd3:  r_dport[7:0]  <= pb;
                        11'd4:  r_seq[31:24]  <= pb;
                        11'd5:  r_seq[23:16]  <= pb;
                        11'd6:  r_seq[15:8]   <= pb;
                        11'd7:  r_seq[7:0]    <= pb;
                        11'd8:  r_ackno[31:24] <= pb;
                        11'd9:  r_ackno[23:16] <= pb;
                        11'd10: r_ackno[15:8]  <= pb;
                        11'd11: r_ackno[7:0]   <= pb;
                        11'd12: r_doff_bytes   <= {2'b00, pb[7:4], 2'b00};
                        11'd13: r_flags        <= pb;
                        default: ;
                        endcase
                        // ones-complement sum over TCP header+payload,
                        // excluding ethernet padding (l4_idx < l4_len)
                        if (l4_idx < {5'd0, l4_len[10:0]} && l4_idx[10:0] < 11'd1600) begin
                            if (l4_idx[0])
                                tcp_sum <= tcp_sum + {24'd0, pb};
                            else
                                tcp_sum <= tcp_sum + {16'd0, pb, 8'd0};
                        end
                    end
                    else if (r_proto == 8'd1) begin
                        if (l4_idx == 11'd0) r_icmp_type <= pb;
                        if (l4_idx == 11'd2) r_icmp_csum[15:8] <= pb;
                        if (l4_idx == 11'd3) r_icmp_csum[7:0]  <= pb;
                        // l4_idx is 11 bits so it always addresses within
                        // the 2048-entry RAM; no explicit bound needed
                        if (!echo_busy)
                            echo_ram[l4_idx] <= pb;
                    end
                end
            end

            if (pb_last) begin
                // frame shorter than the IP header claims -> reject
                if (r_ethtype == 16'h0800 &&
                    (idx + 11'd1) < (11'd14 + {5'd0, r_iplen[10:0]}))
                    r_truncated <= 1'b1;
                pstate   <= P_FINAL;
                fin_step <= 4'd0;
                dbg_rx_frames <= dbg_rx_frames + 32'd1;
            end
        end

        // ---- finalize: add TCP pseudo-header, fold, act ----
        P_FINAL: begin
            fin_step <= fin_step + 4'd1;
            case (fin_step)
            4'd0: tcp_sum <= tcp_sum + {16'd0, r_sip[31:16]};
            4'd1: tcp_sum <= tcp_sum + {16'd0, r_sip[15:0]};
            4'd2: tcp_sum <= tcp_sum + {16'd0, r_dip[31:16]};
            4'd3: tcp_sum <= tcp_sum + {16'd0, r_dip[15:0]};
            4'd4: tcp_sum <= tcp_sum + {16'd0, 8'd0, r_proto};
            4'd5: tcp_sum <= tcp_sum + {16'd0, l4_len};
            4'd6: tcp_sum <= {16'd0, tcp_sum[31:16]} + {16'd0, tcp_sum[15:0]};
            4'd7: tcp_sum <= {16'd0, tcp_sum[31:16]} + {16'd0, tcp_sum[15:0]};
            4'd8: begin
                // ---------- decision ----------
                if (fr_arp_ok && !arp_pending) begin
                    arp_pending <= 1'b1;
                    arp_tha     <= r_arp_sha;
                    arp_tpa     <= r_arp_spa;
                end
                if (fr_icmp_ok) begin
                    echo_busy <= 1'b1;
                    echo_len  <= l4_len;
                    echo_ip   <= r_sip;
                    echo_mac  <= r_sa;
                    // RFC1624: HC' = ~(~HC + ~m + m'), m=0x0800 -> m'=0
                    sum_fold  = {16'd0, ~r_icmp_csum} + 32'h0000F7FF;
                    echo_csum <= ~(sum_fold[15:0] + {15'd0, sum_fold[16]});
                end
                if (fr_tcp_ok && (tcp_sum[15:0] == 16'hFFFF)
                              && (r_dport == LOCAL_PORT)) begin
                    idle_ctr <= 32'd0;
                    if (r_flags[1] && !r_flags[4]) begin
                        // SYN (no ACK): adopt connection from any state
                        peer_mac   <= r_sa;
                        peer_ip    <= r_sip;
                        peer_port  <= r_sport;
                        rcv_nxt    <= r_seq + 32'd1;
                        iss_r      <= iss_ctr;
                        snd_nxt    <= iss_ctr + 32'd1;
                        conn       <= C_SYNR;
                        req_synack <= 1'b1;
                    end
                    else if (peer_match && r_flags[2]) begin
                        conn <= C_LISTEN;               // RST
                    end
                    else if (peer_match) begin
                        case (conn)
                        C_SYNR: begin
                            if (r_flags[4] && (r_ackno == snd_nxt))
                                conn <= C_EST;
                            if (r_seq == rcv_nxt
                                && (payload_len != 16'd0 || r_flags[0])) begin
                                rcv_nxt <= rcv_nxt + {16'd0, payload_len};
                                dbg_tcp_bytes <= dbg_tcp_bytes + {16'd0, payload_len};
                                ack_pending <= 1'b1;
                                if (r_flags[0]) begin   // FIN
                                    rcv_nxt <= rcv_nxt + {16'd0, payload_len} + 32'd1;
                                    finack_seq <= snd_nxt;
                                    snd_nxt    <= snd_nxt + 32'd1;
                                    req_finack <= 1'b1;
                                    ack_pending <= 1'b0;
                                    conn       <= C_LASTACK;
                                end
                            end
                        end
                        C_EST: begin
                            if (r_seq == rcv_nxt) begin
                                rcv_nxt <= rcv_nxt + {16'd0, payload_len};
                                dbg_tcp_bytes <= dbg_tcp_bytes + {16'd0, payload_len};
                                if (r_flags[0]) begin   // FIN
                                    rcv_nxt <= rcv_nxt + {16'd0, payload_len} + 32'd1;
                                    finack_seq <= snd_nxt;
                                    snd_nxt    <= snd_nxt + 32'd1;
                                    req_finack <= 1'b1;
                                    conn       <= C_LASTACK;
                                end else
                                    ack_pending <= 1'b1;
                            end else begin
                                ack_pending <= 1'b1;    // dup/OOO -> dup ACK
                            end
                        end
                        C_LASTACK: begin
                            if (r_flags[4] && (r_ackno == snd_nxt))
                                conn <= C_LISTEN;
                        end
                        default: ;
                        endcase
                    end
                end
                pstate <= P_STREAM;
                idx    <= 11'd0;
            end
            default: ;
            endcase
        end
        endcase
        dbg_state <= {2'b00, conn};
    end
end

// parser consumes whenever streaming (never backpressures mid-frame)
always @(*) fifo_rd = (pstate == P_STREAM);

// =========================================================================
// TX frame generator (tx_clk domain)
// =========================================================================
localparam T_IDLE = 3'd0, T_CSUM = 3'd1, T_FOLD = 3'd2, T_STREAM = 3'd3;
localparam F_ARP = 2'd0, F_SYNACK = 2'd1, F_ACK = 2'd2, F_ECHO = 2'd3;
reg  [2:0]  tstate;
reg  [1:0]  ftype;
reg         f_is_fin;                  // ACK frame carries FIN
reg  [10:0] tx_idx;
reg  [10:0] tx_len;
reg  [15:0] ip_id;
reg  [31:0] ip_sum;
reg  [15:0] ip_csum;
reg  [3:0]  csum_step;
reg  [15:0] t_totlen;
reg  [31:0] t_seq, t_ack;
reg  [31:0] t_dip;
reg  [47:0] t_dmac;
reg  [15:0] t_dport;
reg  [7:0]  t_proto;

reg clr_synack, clr_finack, clr_ack, clr_arp, clr_echo;

wire [10:0] eidx = tx_idx - 11'd34;    // index into ICMP payload on TX

always @(posedge tx_clk) begin
    if (tx_rst) begin
        tstate    <= T_IDLE;
        tx_tvalid <= 1'b0;
        tx_tlast  <= 1'b0;
        ip_id     <= 16'd1;
        clr_synack <= 1'b0; clr_finack <= 1'b0; clr_ack <= 1'b0;
        clr_arp <= 1'b0; clr_echo <= 1'b0;
    end else begin
        clr_synack <= 1'b0; clr_finack <= 1'b0; clr_ack <= 1'b0;
        clr_arp <= 1'b0; clr_echo <= 1'b0;

        case (tstate)
        T_IDLE: if (tx_tvalid && !tx_tready) begin
            // hold the final byte of the previous frame until accepted
        end else begin
            tx_tvalid <= 1'b0;
            tx_tlast  <= 1'b0;
            csum_step <= 4'd0;
            tx_idx    <= 11'd0;
            if (req_synack) begin
                ftype <= F_SYNACK; f_is_fin <= 1'b0;
                t_totlen <= 16'd48; tx_len <= 11'd62;
                t_seq <= iss_r; t_ack <= rcv_nxt;
                t_dip <= peer_ip; t_dmac <= peer_mac; t_dport <= peer_port;
                t_proto <= 8'd6;
                clr_synack <= 1'b1;
                tstate <= T_CSUM;
            end else if (req_finack) begin
                ftype <= F_ACK; f_is_fin <= 1'b1;
                t_totlen <= 16'd40; tx_len <= 11'd54;
                t_seq <= finack_seq; t_ack <= rcv_nxt;
                t_dip <= peer_ip; t_dmac <= peer_mac; t_dport <= peer_port;
                t_proto <= 8'd6;
                clr_finack <= 1'b1;
                tstate <= T_CSUM;
            end else if (arp_pending) begin
                ftype <= F_ARP;
                tx_len <= 11'd42;
                clr_arp <= 1'b1;
                tstate <= T_STREAM;
            end else if (echo_busy) begin
                ftype <= F_ECHO;
                t_totlen <= 16'd20 + echo_len;
                tx_len   <= 11'd34 + echo_len[10:0];
                t_dip <= echo_ip; t_dmac <= echo_mac;
                t_proto <= 8'd1;
                tstate <= T_CSUM;
            end else if (ack_pending) begin
                ftype <= F_ACK; f_is_fin <= 1'b0;
                t_totlen <= 16'd40; tx_len <= 11'd54;
                t_seq <= snd_nxt; t_ack <= rcv_nxt;
                t_dip <= peer_ip; t_dmac <= peer_mac; t_dport <= peer_port;
                t_proto <= 8'd6;
                clr_ack <= 1'b1;
                tstate <= T_CSUM;
            end
        end

        // serial IP header checksum (csum field = 0)
        T_CSUM: begin
            csum_step <= csum_step + 4'd1;
            case (csum_step)
            4'd0: ip_sum <= 32'h00004500 + {16'd0, t_totlen};
            4'd1: ip_sum <= ip_sum + {16'd0, ip_id} + 32'h00004000;
            4'd2: ip_sum <= ip_sum + {16'd0, 8'd64, t_proto};
            4'd3: ip_sum <= ip_sum + {16'd0, LOCAL_IP[31:16]}
                                   + {16'd0, LOCAL_IP[15:0]};
            4'd4: ip_sum <= ip_sum + {16'd0, t_dip[31:16]}
                                   + {16'd0, t_dip[15:0]};
            4'd5: ip_sum <= {16'd0, ip_sum[31:16]} + {16'd0, ip_sum[15:0]};
            4'd6: begin
                ip_csum <= ~(ip_sum[15:0] + {15'd0, |ip_sum[31:16]});
                tstate  <= T_FOLD;
            end
            default: ;
            endcase
        end

        T_FOLD: begin                  // one spare cycle, then stream
            tstate <= T_STREAM;
        end

        T_STREAM: begin
            if (!tx_tvalid || tx_tready) begin
                tx_tvalid <= 1'b1;
                tx_tlast  <= (tx_idx == tx_len - 11'd1);
                tx_idx    <= tx_idx + 11'd1;
                if (tx_idx == tx_len - 11'd1) begin
                    if (ftype != F_ARP) ip_id <= ip_id + 16'd1;
                    if (ftype == F_ECHO) clr_echo <= 1'b1;
                    tstate <= T_IDLE;
                end

                // ---------------- byte mux ----------------
                if (ftype == F_ARP) begin
                    case (tx_idx)
                    11'd0:  tx_tdata <= arp_tha[47:40];
                    11'd1:  tx_tdata <= arp_tha[39:32];
                    11'd2:  tx_tdata <= arp_tha[31:24];
                    11'd3:  tx_tdata <= arp_tha[23:16];
                    11'd4:  tx_tdata <= arp_tha[15:8];
                    11'd5:  tx_tdata <= arp_tha[7:0];
                    11'd6:  tx_tdata <= LOCAL_MAC[47:40];
                    11'd7:  tx_tdata <= LOCAL_MAC[39:32];
                    11'd8:  tx_tdata <= LOCAL_MAC[31:24];
                    11'd9:  tx_tdata <= LOCAL_MAC[23:16];
                    11'd10: tx_tdata <= LOCAL_MAC[15:8];
                    11'd11: tx_tdata <= LOCAL_MAC[7:0];
                    11'd12: tx_tdata <= 8'h08;
                    11'd13: tx_tdata <= 8'h06;
                    11'd14: tx_tdata <= 8'h00;
                    11'd15: tx_tdata <= 8'h01;
                    11'd16: tx_tdata <= 8'h08;
                    11'd17: tx_tdata <= 8'h00;
                    11'd18: tx_tdata <= 8'h06;
                    11'd19: tx_tdata <= 8'h04;
                    11'd20: tx_tdata <= 8'h00;
                    11'd21: tx_tdata <= 8'h02;
                    11'd22: tx_tdata <= LOCAL_MAC[47:40];
                    11'd23: tx_tdata <= LOCAL_MAC[39:32];
                    11'd24: tx_tdata <= LOCAL_MAC[31:24];
                    11'd25: tx_tdata <= LOCAL_MAC[23:16];
                    11'd26: tx_tdata <= LOCAL_MAC[15:8];
                    11'd27: tx_tdata <= LOCAL_MAC[7:0];
                    11'd28: tx_tdata <= LOCAL_IP[31:24];
                    11'd29: tx_tdata <= LOCAL_IP[23:16];
                    11'd30: tx_tdata <= LOCAL_IP[15:8];
                    11'd31: tx_tdata <= LOCAL_IP[7:0];
                    11'd32: tx_tdata <= arp_tha[47:40];
                    11'd33: tx_tdata <= arp_tha[39:32];
                    11'd34: tx_tdata <= arp_tha[31:24];
                    11'd35: tx_tdata <= arp_tha[23:16];
                    11'd36: tx_tdata <= arp_tha[15:8];
                    11'd37: tx_tdata <= arp_tha[7:0];
                    11'd38: tx_tdata <= arp_tpa[31:24];
                    11'd39: tx_tdata <= arp_tpa[23:16];
                    11'd40: tx_tdata <= arp_tpa[15:8];
                    default: tx_tdata <= arp_tpa[7:0];
                    endcase
                end else begin
                    // Ethernet + IPv4 header, shared by TCP/ICMP frames
                    case (tx_idx)
                    11'd0:  tx_tdata <= t_dmac[47:40];
                    11'd1:  tx_tdata <= t_dmac[39:32];
                    11'd2:  tx_tdata <= t_dmac[31:24];
                    11'd3:  tx_tdata <= t_dmac[23:16];
                    11'd4:  tx_tdata <= t_dmac[15:8];
                    11'd5:  tx_tdata <= t_dmac[7:0];
                    11'd6:  tx_tdata <= LOCAL_MAC[47:40];
                    11'd7:  tx_tdata <= LOCAL_MAC[39:32];
                    11'd8:  tx_tdata <= LOCAL_MAC[31:24];
                    11'd9:  tx_tdata <= LOCAL_MAC[23:16];
                    11'd10: tx_tdata <= LOCAL_MAC[15:8];
                    11'd11: tx_tdata <= LOCAL_MAC[7:0];
                    11'd12: tx_tdata <= 8'h08;
                    11'd13: tx_tdata <= 8'h00;
                    11'd14: tx_tdata <= 8'h45;
                    11'd15: tx_tdata <= 8'h00;
                    11'd16: tx_tdata <= t_totlen[15:8];
                    11'd17: tx_tdata <= t_totlen[7:0];
                    11'd18: tx_tdata <= ip_id[15:8];
                    11'd19: tx_tdata <= ip_id[7:0];
                    11'd20: tx_tdata <= 8'h40;
                    11'd21: tx_tdata <= 8'h00;
                    11'd22: tx_tdata <= 8'd64;
                    11'd23: tx_tdata <= t_proto;
                    11'd24: tx_tdata <= ip_csum[15:8];
                    11'd25: tx_tdata <= ip_csum[7:0];
                    11'd26: tx_tdata <= LOCAL_IP[31:24];
                    11'd27: tx_tdata <= LOCAL_IP[23:16];
                    11'd28: tx_tdata <= LOCAL_IP[15:8];
                    11'd29: tx_tdata <= LOCAL_IP[7:0];
                    11'd30: tx_tdata <= t_dip[31:24];
                    11'd31: tx_tdata <= t_dip[23:16];
                    11'd32: tx_tdata <= t_dip[15:8];
                    11'd33: tx_tdata <= t_dip[7:0];
                    default: begin
                        if (ftype == F_ECHO) begin
                            if (eidx == 11'd0)      tx_tdata <= 8'h00;
                            else if (eidx == 11'd1) tx_tdata <= 8'h00;
                            else if (eidx == 11'd2) tx_tdata <= echo_csum[15:8];
                            else if (eidx == 11'd3) tx_tdata <= echo_csum[7:0];
                            else                    tx_tdata <= echo_ram[eidx];
                        end else begin
                            // TCP header (checksum left 0 for MacTxLso)
                            case (tx_idx)
                            11'd34: tx_tdata <= LOCAL_PORT[15:8];
                            11'd35: tx_tdata <= LOCAL_PORT[7:0];
                            11'd36: tx_tdata <= t_dport[15:8];
                            11'd37: tx_tdata <= t_dport[7:0];
                            11'd38: tx_tdata <= t_seq[31:24];
                            11'd39: tx_tdata <= t_seq[23:16];
                            11'd40: tx_tdata <= t_seq[15:8];
                            11'd41: tx_tdata <= t_seq[7:0];
                            11'd42: tx_tdata <= t_ack[31:24];
                            11'd43: tx_tdata <= t_ack[23:16];
                            11'd44: tx_tdata <= t_ack[15:8];
                            11'd45: tx_tdata <= t_ack[7:0];
                            11'd46: tx_tdata <= (ftype == F_SYNACK) ? 8'h70 : 8'h50;
                            11'd47: tx_tdata <= (ftype == F_SYNACK) ? 8'h12
                                              : (f_is_fin ? 8'h11 : 8'h10);
                            11'd48: tx_tdata <= 8'hFF;
                            11'd49: tx_tdata <= 8'hFF;
                            11'd50: tx_tdata <= 8'h00;
                            11'd51: tx_tdata <= 8'h00;
                            11'd52: tx_tdata <= 8'h00;
                            11'd53: tx_tdata <= 8'h00;
                            // SYN-ACK options: MSS 1460, NOP, WScale 4
                            11'd54: tx_tdata <= 8'h02;
                            11'd55: tx_tdata <= 8'h04;
                            11'd56: tx_tdata <= 8'h05;
                            11'd57: tx_tdata <= 8'hB4;
                            11'd58: tx_tdata <= 8'h01;
                            11'd59: tx_tdata <= 8'h03;
                            11'd60: tx_tdata <= 8'h03;
                            default: tx_tdata <= 8'h04;
                            endcase
                        end
                    end
                    endcase
                end
            end
        end
        default: tstate <= T_IDLE;
        endcase
    end
end

endmodule
