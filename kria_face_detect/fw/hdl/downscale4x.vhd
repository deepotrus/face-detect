library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- 4x downscale of a gray stream by 4x4 block averaging (640x480 -> 160x120 by default):
--   out(y, x) = ( sum of in(4y..4y+3, 4x..4x+3) + 8 ) >> 4        (rounded mean)
-- One pixel per beat in and out, raster order. The frame structure comes from the counters
-- (input tlast is not used); m_axis_tlast is set on the last output pixel of the frame.
--
-- Horizontal: 4 consecutive pixels are added in hsum (max 4*255 = 1020, 10 bit).
-- Vertical  : a line buffer of G_WIDTH/4 partial sums (one per output column, max 4080,
--             12 bit) adds the 4 rows; on the 4th row the block sum gives one output pixel.
-- No drain: the last output pixel is complete when the last input pixel arrives.

entity downscale4x is
  generic (
    G_WIDTH  : positive := 640;            -- input pixels per line, multiple of 4
    G_HEIGHT : positive := 480             -- input lines per frame, multiple of 4
  );
  port (
    clk : in std_logic;
    rst : in std_logic;                    -- active high, synchronous

    s_axis_tdata  : in  std_logic_vector(7 downto 0);
    s_axis_tvalid : in  std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in  std_logic;

    m_axis_tdata  : out std_logic_vector(7 downto 0);
    m_axis_tvalid : out std_logic;
    m_axis_tready : in  std_logic;
    m_axis_tlast  : out std_logic
  );
end entity downscale4x;

architecture rtl of downscale4x is

  constant C_OUT_W : positive := G_WIDTH / 4;

  type t_mem is array (0 to C_OUT_W - 1) of unsigned(11 downto 0);
  signal mem : t_mem := (others => (others => '0'));    -- partial vertical sums

  signal in_col : natural range 0 to G_WIDTH - 1  := 0;
  signal in_row : natural range 0 to G_HEIGHT - 1 := 0;
  signal hsum   : unsigned(9 downto 0) := (others => '0');   -- pixels 0..2 of the current group

  signal out_data  : std_logic_vector(7 downto 0) := (others => '0');
  signal out_valid : std_logic := '0';
  signal out_last  : std_logic := '0';

  signal in_ready : std_logic;
  signal in_fire  : std_logic;
  signal out_fire : std_logic;

  signal ocol      : natural range 0 to C_OUT_W - 1;   -- output column of the current group
  signal group_sum : unsigned(9 downto 0);             -- 4 pixels of the group, incl. the incoming one
  signal block_sum : unsigned(11 downto 0);            -- rows above (line buffer) + this group

begin

  -- Room for the output pixel this input may produce: output empty, or emptying now.
  in_ready <= (not out_valid) or m_axis_tready;
  in_fire  <= s_axis_tvalid and in_ready;
  out_fire <= out_valid and m_axis_tready;

  s_axis_tready <= in_ready;
  m_axis_tdata  <= out_data;
  m_axis_tvalid <= out_valid;
  m_axis_tlast  <= out_last;

  ocol      <= in_col / 4;
  group_sum <= hsum + unsigned(s_axis_tdata);
  -- first row of a block row starts from 0 instead of the line buffer
  block_sum <= resize(group_sum, 12) when (in_row mod 4) = 0
          else mem(ocol) + resize(group_sum, 12);

  p_main : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        in_col    <= 0;
        in_row    <= 0;
        hsum      <= (others => '0');
        out_valid <= '0';
        out_last  <= '0';
      else
        if out_fire = '1' then
          out_valid <= '0';
        end if;

        if in_fire = '1' then
          -- horizontal sum over 4 pixels
          if (in_col mod 4) = 3 then
            hsum <= (others => '0');
            if (in_row mod 4) = 3 then
              -- 4th row of the block: rounded mean -> output (after out_fire above: wins)
              out_data  <= std_logic_vector(resize(shift_right(block_sum + 8, 4), 8));
              out_valid <= '1';
              if in_row = G_HEIGHT - 1 and in_col = G_WIDTH - 1 then
                out_last <= '1';
              else
                out_last <= '0';
              end if;
            else
              mem(ocol) <= block_sum;
            end if;
          else
            hsum <= group_sum;
          end if;

          -- input position
          if in_col = G_WIDTH - 1 then
            in_col <= 0;
            if in_row = G_HEIGHT - 1 then
              in_row <= 0;
            else
              in_row <= in_row + 1;
            end if;
          else
            in_col <= in_col + 1;
          end if;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
