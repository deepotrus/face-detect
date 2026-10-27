library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity axis_unpack32to8 is
  port (
    clk : in std_logic;
    rst : in std_logic;

    -- output interface
    m_axis_tdata  : out std_logic_vector(7 downto 0);   -- one Y (gray) pixel
    m_axis_tvalid : out std_logic;                      -- "this pixel is valid now"
    m_axis_tready : in  std_logic;                      -- "Sobel can take it now"
    m_axis_tlast  : out std_logic;                      -- '1' on the very last pixel of the frame

    -- input interface
    s_axis_tdata  : in std_logic_vector(32-1 downto 0);
    s_axis_tvalid : in std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in std_logic
  );
end entity axis_unpack32to8;

architecture rtl of axis_unpack32to8 is

  signal s_axis_tready_i : std_logic;
  signal m_axis_tvalid_i : std_logic := '0';
  signal m_axis_tlast_i  : std_logic := '0';

  signal in_fire : std_logic;
  signal out_fire : std_logic;

  signal last_of_4 : std_logic := '0';
  signal n_pk : natural range 0 to 4-1 := 0;

  signal data_i : std_logic_vector(32-1 downto 0);
  signal tlast_i : std_logic;
begin

  s_axis_tready <= s_axis_tready_i;
  m_axis_tvalid <= m_axis_tvalid_i;
  m_axis_tlast <= m_axis_tlast_i;

  s_axis_tready_i <= (not m_axis_tvalid_i) or (m_axis_tready and last_of_4);  

  last_of_4 <= '1' when n_pk = 3 else '0';
  m_axis_tlast_i <= tlast_i and last_of_4;           -- only byte 3 of the word that came with tlast

  m_axis_tdata <= data_i((n_pk+1)*8-1 downto n_pk*8);

  in_fire <= s_axis_tvalid and s_axis_tready_i;
  out_fire <= m_axis_tvalid_i and m_axis_tready;

  p_unpack : process(clk, rst)
  begin
    if (rst='1') then
      m_axis_tvalid_i <= '0';
      n_pk <= 0;
    elsif (clk'event and clk='1') then

      if (out_fire='1') then
        if (last_of_4 = '1') then
          n_pk <= 0;
          m_axis_tvalid_i <= '0';
        else
          n_pk <= n_pk + 1;
        end if;
      end if;

      if (in_fire = '1') then
        data_i <= s_axis_tdata;
        tlast_i <= s_axis_tlast;
        n_pk <= 0;
        m_axis_tvalid_i <= '1';
      end if;

    end if;
  end process;

end architecture rtl;