-- Testbench for yuyv2gray.
--
-- Sends G_FRAMES YUYV frames of G_WIDTH x G_HEIGHT pixels into the DUT, like one DMA MM2S
-- transfer per frame, and checks that every output word is Y(4w+3) & Y(4w+2) & Y(4w+1) & Y(4w),
-- with tkeep = "1111" and tlast on the last word of each frame (= end of the S2MM transfer).
-- A 640x480 frame is 153 600 input beats (614 400 B) and 76 800 output beats (307 200 B).
-- Frame f runs in phase f mod 4:
--   phase 0: source never idles, sink always ready  -> also checks full rate (no input stalls)
--   phase 1: source inserts random idle cycles
--   phase 2: sink applies random backpressure
--   phase 3: both
-- The default of 4 frames covers each phase once. Simulated time is about 8 ms.
-- In phase 2 frames the sink also holds tready low for G_LONG_STALL_CYCLES in the middle of
-- the frame. At the end the testbench reports how many input beats the DUT took during that
-- stall, and how many words it discarded (words taken in minus words delivered). A correct
-- AXI-Stream block discards nothing: it fills what it can, then lowers tready until the sink
-- is ready again.
-- A protocol checker verifies the AXI-Stream rules on the DUT output: tvalid low in reset,
-- and once tvalid is high, tvalid/tdata/tkeep/tlast stay stable until tready.
--
-- Expected DUT ports (AXI naming, from the DUT's own point of view):
--   aclk, aresetn (active low, synchronous)
--   s_axis_tdata(31:0), s_axis_tkeep(3:0), s_axis_tlast, s_axis_tvalid, s_axis_tready (out)
--   m_axis_tdata(31:0), m_axis_tkeep(3:0), m_axis_tlast, m_axis_tvalid, m_axis_tready (in)
--
-- Run in Vivado: add as simulation source, set as top, Run Behavioral Simulation, then
-- "run all". The simulation stops by itself; the result is in the Tcl console:
--   "tb_yuyv2gray: PASS ..." or "tb_yuyv2gray: FAIL ...".
-- The clock is stopped on purpose at the end (PASS, FAIL or timeout) so that "run all" returns.
-- For quick debugging of the handshake, set G_WIDTH=16, G_HEIGHT=4 in the simulation settings
-- (Simulation -> Elaboration -> Generics) to get short frames.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_yuyv2gray is
  generic (
    G_WIDTH          : positive := 640;   -- pixels per line   (W*H must be a multiple of 4)
    G_HEIGHT         : positive := 480;   -- lines per frame
    G_FRAMES         : positive := 4;     -- frame f runs in phase f mod 4
    G_IDLE_PCT       : natural  := 30;    -- phases 1,3: chance (%) of an idle cycle before a beat
    G_STALL_PCT      : natural  := 40;    -- phases 2,3: chance (%) of tready low in a cycle
    G_REQUIRE_FULL   : boolean  := true;  -- phase 0: fail if the DUT ever stalls the input
    G_LONG_STALL_CYCLES : natural := 1000; -- phase 2: sink holds tready low this long mid-frame
    G_TIMEOUT_CYCLES : positive := 2000   -- fail if no output beat for this many cycles
  );
end entity tb_yuyv2gray;

architecture sim of tb_yuyv2gray is

  constant C_CLK_PERIOD : time    := 10 ns;              -- 100 MHz, like pl_clk0
  constant C_PIXELS     : natural := G_WIDTH * G_HEIGHT;
  constant C_IN_BEATS   : natural := C_PIXELS / 2;       -- 2 pixels per YUYV beat
  constant C_OUT_BEATS  : natural := C_PIXELS / 4;       -- 4 gray pixels per output word

  signal aclk    : std_logic := '0';
  signal aresetn : std_logic := '0';
  signal done    : boolean   := false;                   -- stops the clock

  signal s_axis_tdata  : std_logic_vector(31 downto 0) := (others => '0');
  signal s_axis_tkeep  : std_logic_vector(3 downto 0)  := (others => '0');
  signal s_axis_tlast  : std_logic := '0';
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;

  signal m_axis_tdata  : std_logic_vector(31 downto 0);
  signal m_axis_tkeep  : std_logic_vector(3 downto 0);
  signal m_axis_tlast  : std_logic;
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '0';

  signal errors        : natural := 0;                   -- written only by p_sink
  signal proto_errors  : natural := 0;                   -- written only by p_protocol
  signal input_stalls  : natural := 0;                   -- written only by p_source
  signal in_beats      : natural := 0;                   -- input beats taken by the DUT (p_source)
  signal stall_in_beats : natural := 0;                  -- ... of which during a long stall
  signal long_stall    : boolean := false;               -- p_sink is in a long stall
  signal long_stalls   : natural := 0;                   -- long stalls done (p_sink)
  signal out_beats     : natural := 0;
  signal last_out_time : time    := 0 ns;

  -- Test pattern. Y changes with pixel and frame; U and V use values Y never takes at the
  -- same position, so a DUT that leaks chroma into the output is caught.
  function y_of(frame, pixel : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((pixel * 7 + frame * 31 + 1) mod 256, 8));
  end function;

  function u_of(frame, beat : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((beat * 7 + frame * 31 + 129) mod 256, 8));
  end function;

  function v_of(frame, beat : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned((beat * 7 + frame * 31 + 200) mod 256, 8));
  end function;

  -- input beat b of a frame = pixels 2b, 2b+1:  V & Y1 & U & Y0
  function in_beat(frame, beat : natural) return std_logic_vector is
  begin
    return v_of(frame, beat) & y_of(frame, 2 * beat + 1) & u_of(frame, beat) & y_of(frame, 2 * beat);
  end function;

  -- output word w of a frame = pixels 4w..4w+3:  Y3 & Y2 & Y1 & Y0
  function out_word(frame, word : natural) return std_logic_vector is
  begin
    return y_of(frame, 4 * word + 3) & y_of(frame, 4 * word + 2) &
           y_of(frame, 4 * word + 1) & y_of(frame, 4 * word);
  end function;

  function hex(v : std_logic_vector) return string is
    constant C_DIGITS : string(1 to 16) := "0123456789ABCDEF";
    alias    nv       : std_logic_vector(v'length - 1 downto 0) is v;  -- '&' results may be "to"
    variable r        : string(1 to v'length / 4);
    variable nib      : std_logic_vector(3 downto 0);
  begin
    for i in r'range loop
      nib := nv(nv'high - 4 * (i - 1) downto nv'high - 4 * (i - 1) - 3);
      if is_x(nib) then
        r(i) := 'X';
      else
        r(i) := C_DIGITS(to_integer(unsigned(nib)) + 1);
      end if;
    end loop;
    return r;
  end function;

  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

  -- true with probability pct %
  procedure chance(pct : natural; variable s1, s2 : inout positive; variable hit : out boolean) is
    variable r : real;
  begin
    uniform(s1, s2, r);
    hit := r * 100.0 < real(pct);
  end procedure;

  signal areset : std_logic;
begin

  assert C_PIXELS mod 4 = 0 report "G_WIDTH*G_HEIGHT must be a multiple of 4" severity failure;
  assert G_LONG_STALL_CYCLES < G_TIMEOUT_CYCLES
    report "G_LONG_STALL_CYCLES must be below G_TIMEOUT_CYCLES" severity failure;

  aclk <= not aclk after C_CLK_PERIOD / 2 when not done else '0';

  dut : entity work.yuyv2gray
    port map (
      clk => aclk,
      rst => areset,
      -- DUT input: the stream coming from the DMA MM2S channel (played by p_source)
      m_axis_mm2s_tdata  => s_axis_tdata,
      m_axis_mm2s_tkeep  => s_axis_tkeep,
      m_axis_mm2s_tlast  => s_axis_tlast,
      m_axis_mm2s_tvalid => s_axis_tvalid,
      m_axis_mm2s_tready => s_axis_tready,
      -- DUT output: the stream going to the DMA S2MM channel (played by p_sink)
      s_axis_s2mm_tdata  => m_axis_tdata,
      s_axis_s2mm_tkeep  => m_axis_tkeep,
      s_axis_s2mm_tlast  => m_axis_tlast,
      s_axis_s2mm_tvalid => m_axis_tvalid,
      s_axis_s2mm_tready => m_axis_tready
    );

  areset <= not aresetn;

  p_reset : process
  begin
    aresetn <= '0';
    for i in 1 to 10 loop
      wait until rising_edge(aclk);
    end loop;
    aresetn <= '1';
    wait;
  end process;

  -- Source: plays the role of the DMA MM2S channel.
  p_source : process
    variable s1, s2  : positive := 17;
    variable idle    : boolean;
    variable phase   : natural;
    variable stalls  : natural := 0;
    variable taken   : natural := 0;
    variable taken_s : natural := 0;
  begin
    s2 := 4242;
    wait until aresetn = '1';
    wait until rising_edge(aclk);

    for f in 0 to G_FRAMES - 1 loop
      phase := f mod 4;
      for b in 0 to C_IN_BEATS - 1 loop
        if phase = 1 or phase = 3 then              -- random idle cycles, tvalid low
          loop
            chance(G_IDLE_PCT, s1, s2, idle);
            exit when not idle;
            s_axis_tvalid <= '0';
            s_axis_tdata  <= (others => 'X');         -- data is meaningless while not valid
            wait until rising_edge(aclk);
          end loop;
        end if;

        s_axis_tdata  <= in_beat(f, b);
        s_axis_tkeep  <= "1111";
        s_axis_tlast  <= to_sl(b = C_IN_BEATS - 1);
        s_axis_tvalid <= '1';

        loop                                        -- hold the beat until it is accepted
          wait until rising_edge(aclk);
          if s_axis_tready = '1' then
            taken    := taken + 1;
            in_beats <= taken;
            if long_stall then
              taken_s        := taken_s + 1;
              stall_in_beats <= taken_s;
            end if;
            exit;
          end if;
          if phase = 0 then
            stalls := stalls + 1;
            input_stalls <= stalls;
          end if;
        end loop;
      end loop;
    end loop;

    s_axis_tvalid <= '0';
    s_axis_tlast  <= '0';
    s_axis_tdata  <= (others => 'X');
    wait;
  end process;

  -- Sink: plays the role of the DMA S2MM channel, and checks every word it receives.
  p_sink : process
    variable s1, s2 : positive := 99;
    variable stall  : boolean;
    variable frame  : natural := 0;
    variable word   : natural := 0;
    variable errs   : natural := 0;
    variable beats  : natural := 0;
    variable phase  : natural;
    variable stalled_frame : integer := -1;         -- last frame that got its long stall

    procedure fail(msg : string) is
    begin
      errs := errs + 1;
      if errs <= 20 then
        report "frame " & integer'image(frame) & " word " & integer'image(word) & ": " & msg
          severity error;
      end if;
    end procedure;
  begin
    s2 := 777;
    m_axis_tready <= '0';
    wait until aresetn = '1';

    while frame < G_FRAMES loop
      phase := frame mod 4;

      if phase = 2 and word = C_OUT_BEATS / 2 and stalled_frame /= frame and G_LONG_STALL_CYCLES > 0 then
        stalled_frame := frame;                   -- long stall: tready low, nothing is taken
        m_axis_tready <= '0';
        long_stall    <= true;
        for i in 1 to G_LONG_STALL_CYCLES loop
          wait until rising_edge(aclk);
        end loop;
        long_stall    <= false;
        long_stalls   <= long_stalls + 1;
        last_out_time <= now;                     -- the stall is ours, not a DUT timeout
      end if;

      if phase = 2 or phase = 3 then
        chance(G_STALL_PCT, s1, s2, stall);
        m_axis_tready <= to_sl(not stall);
      else
        m_axis_tready <= '1';
      end if;

      wait until rising_edge(aclk);

      if m_axis_tvalid = '1' and m_axis_tready = '1' then
        beats := beats + 1;
        out_beats     <= beats;
        last_out_time <= now;

        if m_axis_tdata /= out_word(frame, word) then
          fail("tdata = " & hex(m_axis_tdata) & ", expected " & hex(out_word(frame, word)));
        end if;
        if m_axis_tkeep /= "1111" then
          fail("tkeep = " & hex(m_axis_tkeep) & ", expected F");
        end if;
        if m_axis_tlast /= to_sl(word = C_OUT_BEATS - 1) then
          fail("tlast = " & std_logic'image(m_axis_tlast) & ", expected tlast only on word " &
               integer'image(C_OUT_BEATS - 1));
        end if;

        if word = C_OUT_BEATS - 1 then
          word  := 0;
          frame := frame + 1;
        else
          word := word + 1;
        end if;
      end if;
      errors <= errs;
    end loop;

    -- the DUT must not produce anything after the last frame
    m_axis_tready <= '1';
    for i in 1 to 50 loop
      wait until rising_edge(aclk);
      if m_axis_tvalid = '1' then
        fail("extra output beat after the last frame: " & hex(m_axis_tdata));
      end if;
    end loop;
    errors <= errs;
    wait;
  end process;

  -- AXI-Stream rules on the DUT output (and tready sanity on its input).
  p_protocol : process
    variable held  : boolean := false;     -- previous edge had tvalid=1, tready=0
    variable pdata : std_logic_vector(31 downto 0);
    variable pkeep : std_logic_vector(3 downto 0);
    variable plast : std_logic;
    variable errs  : natural := 0;

    procedure fail(msg : string) is
    begin
      errs := errs + 1;
      if errs <= 20 then
        report "protocol: " & msg severity error;
      end if;
      proto_errors <= errs;
    end procedure;
  begin
    wait until rising_edge(aclk);

    if aresetn = '0' then
      if m_axis_tvalid /= '0' then
        fail("m_axis_tvalid must be 0 during reset, is " & std_logic'image(m_axis_tvalid));
      end if;
      held := false;
    else
      if m_axis_tvalid /= '0' and m_axis_tvalid /= '1' then
        fail("m_axis_tvalid is " & std_logic'image(m_axis_tvalid));
      end if;
      if s_axis_tready /= '0' and s_axis_tready /= '1' then
        fail("s_axis_tready is " & std_logic'image(s_axis_tready));
      end if;

      if held then
        if m_axis_tvalid /= '1' then
          fail("m_axis_tvalid dropped before the beat was accepted");
        elsif m_axis_tdata /= pdata or m_axis_tkeep /= pkeep or m_axis_tlast /= plast then
          fail("m_axis_tdata/tkeep/tlast changed while waiting for tready (" &
               hex(pdata) & " -> " & hex(m_axis_tdata) & ")");
        end if;
      end if;

      held  := m_axis_tvalid = '1' and m_axis_tready = '0';
      pdata := m_axis_tdata;
      pkeep := m_axis_tkeep;
      plast := m_axis_tlast;
    end if;
  end process;

  -- Ends the simulation: when the sink has finished, or when the DUT stops producing output.
  p_control : process
    variable total : natural;
  begin
    wait until aresetn = '1';

    loop
      wait until rising_edge(aclk);
      exit when out_beats = G_FRAMES * C_OUT_BEATS;
      if now - last_out_time > G_TIMEOUT_CYCLES * C_CLK_PERIOD and now > G_TIMEOUT_CYCLES * C_CLK_PERIOD then
        report "timeout: no output beat for " & integer'image(G_TIMEOUT_CYCLES) & " cycles after " &
               integer'image(out_beats) & " of " & integer'image(G_FRAMES * C_OUT_BEATS) &
               " beats (DUT stuck? check s_axis_tready / m_axis_tvalid)" severity error;
        exit;
      end if;
    end loop;

    for i in 1 to 60 loop                       -- let the sink run its after-the-end check
      wait until rising_edge(aclk);
    end loop;

    total := errors + proto_errors;
    if out_beats /= G_FRAMES * C_OUT_BEATS then
      total := total + 1;
    end if;

    if long_stalls > 0 then
      report "long stall: sink held tready low " & integer'image(long_stalls) & " time(s) for " &
             integer'image(G_LONG_STALL_CYCLES) & " cycles; the DUT took " &
             integer'image(stall_in_beats) & " input beat(s) during the stall(s)"
        severity note;
    end if;
    report "words taken in: " & integer'image(in_beats / 2) & ", delivered: " &
           integer'image(out_beats) & ", discarded: " & integer'image(in_beats / 2 - out_beats)
      severity note;
    if in_beats / 2 /= out_beats then
      total := total + 1;
    end if;
    if G_REQUIRE_FULL and input_stalls > 0 then
      report "phase 0: the DUT stalled the input " & integer'image(input_stalls) &
             " times with the output always ready (expected 0, i.e. one input beat per clock)"
        severity error;
      total := total + 1;
    end if;

    if total = 0 then
      report "tb_yuyv2gray: PASS (" & integer'image(G_FRAMES) & " frames, " &
             integer'image(out_beats) & " output words)" severity note;
    else
      report "tb_yuyv2gray: FAIL (" & integer'image(errors) & " data errors, " &
             integer'image(proto_errors) & " protocol errors, " &
             integer'image(input_stalls) & " phase-0 input stalls, " &
             integer'image(out_beats) & "/" & integer'image(G_FRAMES * C_OUT_BEATS) &
             " output words)" severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
