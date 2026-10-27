library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity sobel3x3 is
  generic (
    G_WIDTH  : positive := 640;
    G_HEIGHT : positive := 480
  );
  port (
    clk : in std_logic;
    rst : in std_logic;

    -- output interface
    m_axis_tdata  : out std_logic_vector(8-1 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic;

    -- input interface
    s_axis_tdata  : in std_logic_vector(8-1 downto 0);
    s_axis_tvalid : in std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in std_logic
  );
end entity sobel3x3;

architecture rtl of sobel3x3 is

  signal m_axis_tvalid_i : std_logic := '0';
  signal m_axis_tlast_i  : std_logic := '0';
  signal s_axis_tready_i : std_logic;

  signal in_fire : std_logic;
  signal out_fire : std_logic;

  type t_mem is array (0 to G_WIDTH-1) of std_logic_vector(16-1 downto 0);
  signal mem : t_mem := (others => (others => '0'));

  signal up1 : std_logic_vector(8-1 downto 0);
  signal up2 : std_logic_vector(8-1 downto 0);

  -- first pair of counters
  signal in_row : natural range 0 to G_HEIGHT-1 := 0;
  signal in_col : natural range 0 to G_WIDTH-1 := 0;

  -- second pair of counter for the output stage
  signal out_row : natural range 0 to G_HEIGHT-1 := 0;
  signal out_col : natural range 0 to G_WIDTH-1 := 0;

  signal border_flag : std_logic;
  signal draining_out : std_logic := '0';

  -- sobel filter cells
  signal w00, w01, w02, w10, w11, w12, w20, w21, w22 : std_logic_vector(7 downto 0) := (others=>'0');

-- Sobel magnitude of a 3x3 window: min(255, |Gx| + |Gy|). The centre pixel is not used
  function sobel_filt(a00, a01, a02, a10, a12, a20, a21, a22 : std_logic_vector(7 downto 0))
    return std_logic_vector is
    variable gx, gy, m : integer;
  begin
    gx := (to_integer(unsigned(a02)) + 2 * to_integer(unsigned(a12)) + to_integer(unsigned(a22)))
        - (to_integer(unsigned(a00)) + 2 * to_integer(unsigned(a10)) + to_integer(unsigned(a20)));
    gy := (to_integer(unsigned(a20)) + 2 * to_integer(unsigned(a21)) + to_integer(unsigned(a22)))
        - (to_integer(unsigned(a00)) + 2 * to_integer(unsigned(a01)) + to_integer(unsigned(a02)));
    m := abs(gx) + abs(gy);
    if m > 255 then
      m := 255;
    end if;
    return std_logic_vector(to_unsigned(m, 8));
  end function;

  signal sobel : std_logic_vector(7 downto 0);

begin

  m_axis_tvalid <= m_axis_tvalid_i;
  m_axis_tlast <= m_axis_tlast_i;
  s_axis_tready <= s_axis_tready_i;

  in_fire <= s_axis_tvalid and s_axis_tready_i;
  out_fire <= m_axis_tvalid_i and m_axis_tready;

  s_axis_tready_i <= '0' when draining_out = '1' else (not m_axis_tvalid_i) or m_axis_tready;

  up2 <= mem(in_col)(16-1 downto 8);
  up1 <= mem(in_col)(8-1 downto 0);
  sobel <= sobel_filt(w01, w02, up2,
                      w11,      up1,
                      w21, w22, s_axis_tdata);

  p_stage : process(clk, rst)
    -- output logic happens in 2 places: while in_fire high, and while draining
    procedure emit(pixel : std_logic_vector(8-1 downto 0)) is
    begin
      -- emitting logic
      if (border_flag ='1') then
        m_axis_tdata <= (others => '0');
      else
        m_axis_tdata <= pixel;
      end if;

      -- counters update
      out_col <= out_col + 1;
      if (out_col = G_WIDTH-1) then
        out_row <= out_row + 1;
        out_col <= 0;
      end if;

      -- edge case, frame finished
      if (out_row = G_HEIGHT-1 and out_col = G_WIDTH-1) then
        m_axis_tlast_i <='1';
        out_row <= 0;
        draining_out <= '0'; -- draining finishes
      else
        m_axis_tlast_i <='0';
      end if;
      
    end procedure;
  begin
    if (rst='1') then
      m_axis_tvalid_i <= '0';
      in_col <= 0;
      in_row <= 0;
      out_row <= 0;
      out_col <= 0;
      draining_out <= '0';

    elsif (clk'event and clk='1') then

      -- output firing
      if (out_fire = '1') then
        m_axis_tvalid_i <= '0';
      end if;

      -- input firing
      if (in_fire = '1') then
        in_col <= in_col + 1;

        mem(in_col) <= up1 & s_axis_tdata;

        if (in_col = G_WIDTH-1) then
          in_col <= 0;
          in_row <= in_row + 1;
          if (in_row = G_HEIGHT-1) then
            in_row <= 0;
            draining_out <= '1';
          end if;
        end if;

        -- shifting filter logic: new column adds to the right
        w00 <= w01; w01 <= w02; w02 <= up2;
        w10 <= w11; w11 <= w12; w12 <= up1;
        w20 <= w21; w21 <= w22; w22 <= s_axis_tdata;

        -- fire out the pixel
        if ((in_row > 1) or (in_row = 1 and in_col >= 1) ) then -- 3x3 filter is defined)
          m_axis_tvalid_i <= '1';
          --emit(w12); -- fire the center of the filter
          emit(sobel); -- fire the sobel magnitude
        end if;

      elsif (draining_out = '1' and (m_axis_tvalid_i = '0' or m_axis_tready = '1')) then -- draining logic mutually exclusive with in_fire
        m_axis_tvalid_i <= '1';
        --emit(w12); -- fire the center of the filter
        emit(sobel); -- fire the sobel magnitude
      end if;
    end if;
  end process;

  border_flag <= '1' when (out_row = 0 or out_row = G_HEIGHT-1 or out_col = 0 or out_col = G_WIDTH-1) else '0';

end architecture rtl;