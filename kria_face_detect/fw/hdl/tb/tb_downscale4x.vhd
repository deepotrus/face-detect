-- Testbench for downscale4x.
--
-- Sends G_FRAMES gray frames of G_WIDTH x G_HEIGHT pixels (one pixel per beat, raster order)
-- and checks every output pixel against the model
--   out(y, x) = ( sum of in(4y..4y+3, 4x..4x+3) + 8 ) / 16
-- with m_axis_tlast only on the last output pixel of each frame.
-- Frame f runs in phase f mod 4:
--   phase 0: source never idles, sink always ready  -> also checks full rate:
--            the DUT must accept an input pixel on every clock
--   phase 1: source inserts random idle cycles
--   phase 2: sink applies random backpressure, plus one G_LONG_STALL_CYCLES stall mid-frame
--   phase 3: both
-- A protocol checker verifies the AXI-Stream rules on the DUT output.
-- The simulation ends by itself with one line:
--   "tb_downscale4x: PASS (...)" or "tb_downscale4x: FAIL (...)"
--
-- For a readable waveform use small frames: G_WIDTH=16, G_HEIGHT=8.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_downscale4x is
  generic (
    G_WIDTH             : positive := 640;
    G_HEIGHT            : positive := 480;
    G_FRAMES            : positive := 4;      -- frame f runs in phase f mod 4
    G_IDLE_PCT          : natural  := 30;     -- phases 1,3: chance (%) of an idle cycle before a pixel
    G_STALL_PCT         : natural  := 40;     -- phases 2,3: chance (%) of tready low in a cycle
    G_LONG_STALL_CYCLES : natural  := 1000;   -- phase 2: one long stall mid-frame
    G_REQUIRE_FULL      : boolean  := true;   -- phase 0: fail on any input stall
    G_TIMEOUT_CYCLES    : positive := 4000    -- fail if no output pixel for this many cycles
  );
end entity tb_downscale4x;

architecture sim of tb_downscale4x is

  constant C_CLK_PERIOD : time    := 10 ns;
  constant C_OUT_W      : natural := G_WIDTH / 4;
  constant C_OUT_H      : natural := G_HEIGHT / 4;
  constant C_OUT_PIX    : natural := C_OUT_W * C_OUT_H;

  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal done : boolean   := false;

  signal s_axis_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_axis_tlast  : std_logic := '0';
  signal s_axis_tvalid : std_logic := '0';
  signal s_axis_tready : std_logic;

  signal m_axis_tdata  : std_logic_vector(7 downto 0);
  signal m_axis_tlast  : std_logic;
  signal m_axis_tvalid : std_logic;
  signal m_axis_tready : std_logic := '0';

  signal errors        : natural := 0;   -- p_sink
  signal proto_errors  : natural := 0;   -- p_protocol
  signal input_stalls  : natural := 0;   -- p_source
  signal in_pixels     : natural := 0;   -- p_source
  signal out_pixels    : natural := 0;   -- p_sink
  signal last_out_time : time    := 0 ns;

  -- Test image: pseudo-random pixels, different per frame (exercises the rounding and the
  -- full 0..255 range, and a misplaced pixel or block never matches by accident).
  function pix_of(frame, y, x : natural) return natural is
  begin
    return (x * 37 + y * 101 + frame * 53 + (x * y) mod 251 + (x * x) mod 17) mod 256;
  end function;

  function expected(frame, y, x : natural) return natural is
    variable s : natural := 0;
  begin
    for dy in 0 to 3 loop
      for dx in 0 to 3 loop
        s := s + pix_of(frame, 4 * y + dy, 4 * x + dx);
      end loop;
    end loop;
    return (s + 8) / 16;
  end function;

  function hex(v : std_logic_vector) return string is
    constant C_DIGITS : string(1 to 16) := "0123456789ABCDEF";
    alias    nv       : std_logic_vector(v'length - 1 downto 0) is v;
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

  procedure chance(pct : natural; variable s1, s2 : inout positive; variable hit : out boolean) is
    variable r : real;
  begin
    uniform(s1, s2, r);
    hit := r * 100.0 < real(pct);
  end procedure;

begin

  assert G_WIDTH mod 4 = 0 and G_HEIGHT mod 4 = 0
    report "G_WIDTH and G_HEIGHT must be multiples of 4" severity failure;
  assert G_LONG_STALL_CYCLES < G_TIMEOUT_CYCLES
    report "G_LONG_STALL_CYCLES must be below G_TIMEOUT_CYCLES" severity failure;

  clk <= not clk after C_CLK_PERIOD / 2 when not done else '0';

  dut : entity work.downscale4x
    generic map (
      G_WIDTH  => G_WIDTH,
      G_HEIGHT => G_HEIGHT
    )
    port map (
      clk           => clk,
      rst           => rst,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      s_axis_tlast  => s_axis_tlast,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      m_axis_tlast  => m_axis_tlast
    );

  p_reset : process
  begin
    rst <= '1';
    for i in 1 to 10 loop
      wait until rising_edge(clk);
    end loop;
    rst <= '0';
    wait;
  end process;

  -- Source: plays axis_unpack32to8 (one gray pixel per beat, raster order).
  p_source : process
    variable s1, s2 : positive := 17;
    variable idle   : boolean;
    variable phase  : natural;
    variable taken  : natural := 0;
    variable stalls : natural := 0;
  begin
    s2 := 4242;
    wait until rst = '0';
    wait until rising_edge(clk);

    for f in 0 to G_FRAMES - 1 loop
      phase := f mod 4;
      for y in 0 to G_HEIGHT - 1 loop
        for x in 0 to G_WIDTH - 1 loop
          if phase = 1 or phase = 3 then
            loop
              chance(G_IDLE_PCT, s1, s2, idle);
              exit when not idle;
              s_axis_tvalid <= '0';
              s_axis_tdata  <= (others => 'X');
              wait until rising_edge(clk);
            end loop;
          end if;

          s_axis_tdata  <= std_logic_vector(to_unsigned(pix_of(f, y, x), 8));
          s_axis_tlast  <= to_sl(y = G_HEIGHT - 1 and x = G_WIDTH - 1);
          s_axis_tvalid <= '1';

          loop
            wait until rising_edge(clk);
            if s_axis_tready = '1' then
              taken     := taken + 1;
              in_pixels <= taken;
              exit;
            end if;
            if phase = 0 then
              stalls := stalls + 1;
              input_stalls <= stalls;
            end if;
          end loop;
        end loop;
      end loop;
    end loop;

    s_axis_tvalid <= '0';
    s_axis_tlast  <= '0';
    s_axis_tdata  <= (others => 'X');
    wait;
  end process;

  -- Sink: plays the FINN IP and checks every output pixel.
  p_sink : process
    variable s1, s2  : positive := 99;
    variable stall   : boolean;
    variable frame   : natural := 0;
    variable k       : natural := 0;       -- output pixel index in the frame
    variable errs    : natural := 0;
    variable count   : natural := 0;
    variable phase   : natural;
    variable stalled_frame : integer := -1;
    variable exp     : natural;

    procedure fail(msg : string) is
    begin
      errs := errs + 1;
      if errs <= 20 then
        report "frame " & integer'image(frame) & " pixel (y=" & integer'image(k / C_OUT_W) &
               ", x=" & integer'image(k mod C_OUT_W) & "): " & msg severity error;
      end if;
    end procedure;
  begin
    s2 := 777;
    m_axis_tready <= '0';
    wait until rst = '0';

    while frame < G_FRAMES loop
      phase := frame mod 4;

      if phase = 2 and k = C_OUT_PIX / 2 and stalled_frame /= frame and G_LONG_STALL_CYCLES > 0 then
        stalled_frame := frame;
        m_axis_tready <= '0';
        for i in 1 to G_LONG_STALL_CYCLES loop
          wait until rising_edge(clk);
        end loop;
        last_out_time <= now;
      end if;

      if phase = 2 or phase = 3 then
        chance(G_STALL_PCT, s1, s2, stall);
        m_axis_tready <= to_sl(not stall);
      else
        m_axis_tready <= '1';
      end if;

      wait until rising_edge(clk);

      if m_axis_tvalid = '1' and m_axis_tready = '1' then
        count := count + 1;
        out_pixels    <= count;
        last_out_time <= now;

        exp := expected(frame, k / C_OUT_W, k mod C_OUT_W);
        if is_x(m_axis_tdata) or to_integer(unsigned(m_axis_tdata)) /= exp then
          fail("tdata = " & hex(m_axis_tdata) & ", expected " &
               hex(std_logic_vector(to_unsigned(exp, 8))));
        end if;
        if m_axis_tlast /= to_sl(k = C_OUT_PIX - 1) then
          fail("tlast = " & std_logic'image(m_axis_tlast) & ", expected tlast only on the last pixel");
        end if;

        if k = C_OUT_PIX - 1 then
          k     := 0;
          frame := frame + 1;
        else
          k := k + 1;
        end if;
      end if;
      errors <= errs;
    end loop;

    m_axis_tready <= '1';
    for i in 1 to 50 loop
      wait until rising_edge(clk);
      if m_axis_tvalid = '1' then
        fail("extra output pixel after the last frame: " & hex(m_axis_tdata));
      end if;
    end loop;
    errors <= errs;
    wait;
  end process;

  -- AXI-Stream rules on the DUT output, and tready sanity on its input.
  p_protocol : process
    variable held  : boolean := false;
    variable pdata : std_logic_vector(7 downto 0);
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
    wait until rising_edge(clk);

    if rst = '1' then
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
          fail("m_axis_tvalid dropped before the pixel was accepted");
        elsif m_axis_tdata /= pdata or m_axis_tlast /= plast then
          fail("m_axis_tdata/tlast changed while waiting for tready (" &
               hex(pdata) & " -> " & hex(m_axis_tdata) & ")");
        end if;
      end if;

      held  := m_axis_tvalid = '1' and m_axis_tready = '0';
      pdata := m_axis_tdata;
      plast := m_axis_tlast;
    end if;
  end process;

  p_control : process
    variable total : natural;
  begin
    wait until rst = '0';

    loop
      wait until rising_edge(clk);
      exit when out_pixels = G_FRAMES * C_OUT_PIX;
      if now - last_out_time > G_TIMEOUT_CYCLES * C_CLK_PERIOD and now > G_TIMEOUT_CYCLES * C_CLK_PERIOD then
        report "timeout: no output pixel for " & integer'image(G_TIMEOUT_CYCLES) & " cycles after " &
               integer'image(out_pixels) & " of " & integer'image(G_FRAMES * C_OUT_PIX) &
               " pixels (DUT stuck? check s_axis_tready / m_axis_tvalid)" severity error;
        exit;
      end if;
    end loop;

    for i in 1 to 60 loop
      wait until rising_edge(clk);
    end loop;

    total := errors + proto_errors;
    report "pixels in: " & integer'image(in_pixels) & " (expected " &
           integer'image(G_FRAMES * G_WIDTH * G_HEIGHT) & "), out: " & integer'image(out_pixels) &
           " (expected " & integer'image(G_FRAMES * C_OUT_PIX) & ")" severity note;
    if out_pixels /= G_FRAMES * C_OUT_PIX or in_pixels /= G_FRAMES * G_WIDTH * G_HEIGHT then
      total := total + 1;
    end if;
    if G_REQUIRE_FULL and input_stalls > 0 then
      report "phase 0: the DUT refused a pixel " & integer'image(input_stalls) &
             " times with the output always ready (expected 0, i.e. one pixel per clock)"
        severity error;
      total := total + 1;
    end if;

    if total = 0 then
      report "tb_downscale4x: PASS (" & integer'image(G_FRAMES) & " frames of " &
             integer'image(G_WIDTH) & "x" & integer'image(G_HEIGHT) & " -> " &
             integer'image(C_OUT_W) & "x" & integer'image(C_OUT_H) & ", " &
             integer'image(out_pixels) & " output pixels)" severity note;
    else
      report "tb_downscale4x: FAIL (" & integer'image(errors) & " data errors, " &
             integer'image(proto_errors) & " protocol errors, " &
             integer'image(input_stalls) & " phase-0 input stalls, " &
             integer'image(out_pixels) & "/" & integer'image(G_FRAMES * C_OUT_PIX) & " pixels)"
        severity error;
    end if;
    done <= true;
    wait;
  end process;

end architecture sim;
