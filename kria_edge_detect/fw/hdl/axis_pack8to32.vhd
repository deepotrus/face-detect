library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity axis_pack8to32 is
  port (
    clk : in std_logic;
    rst : in std_logic;

    -- output interface
    m_axis_tdata  : out std_logic_vector(32-1 downto 0);   -- one Y (gray) pixel
    m_axis_tvalid : out std_logic;                      -- "this pixel is valid now"
    m_axis_tready : in  std_logic;                      -- "Sobel can take it now"
    m_axis_tlast  : out std_logic;                      -- '1' on the very last pixel of the frame
    m_axis_tkeep  : out std_logic_vector(3 downto 0) := "1111";

    -- input interface
    s_axis_tdata  : in std_logic_vector(8-1 downto 0);
    s_axis_tvalid : in std_logic;
    s_axis_tready : out std_logic;
    s_axis_tlast  : in std_logic
  );
end entity axis_pack8to32;

architecture rtl of axis_pack8to32 is

  signal s_axis_tready_i : std_logic;
  signal m_axis_tvalid_i : std_logic := '0';
  signal m_axis_tlast_i  : std_logic := '0';

  signal in_fire : std_logic;
  signal out_fire : std_logic;

  signal n_pk : natural range 0 to 4-1 := 0;
  signal data_i : std_logic_vector(32-1 downto 0);
  signal last_of_4 : std_logic;
begin

  s_axis_tready <= s_axis_tready_i;
  m_axis_tvalid <= m_axis_tvalid_i;
  m_axis_tlast <= m_axis_tlast_i;

  in_fire <= s_axis_tvalid and s_axis_tready_i;
  out_fire <= m_axis_tvalid_i and m_axis_tready;

  last_of_4 <= '1' when n_pk = 3 else '0'; 

  s_axis_tready_i <= '1' when last_of_4 = '0'
                else ( (not m_axis_tvalid_i) or m_axis_tready);

  p_pack : process(clk, rst)
  begin
    if (rst='1') then
      m_axis_tvalid_i <= '0';
      n_pk <= 0;
    elsif (clk'event and clk='1') then

      if (out_fire = '1') then
        m_axis_tvalid_i <= '0';
      end if;

      if (in_fire = '1') then
        case n_pk is
          when 0 =>
            data_i(8-1 downto 0) <= s_axis_tdata;
            n_pk <= n_pk + 1;
          when 1 => 
            data_i(16-1 downto 8) <= s_axis_tdata;
            n_pk <= n_pk + 1;
          when 2 => 
            data_i(24-1 downto 16) <= s_axis_tdata;
            n_pk <= n_pk + 1;
          when 3 => 
            data_i(32-1 downto 24) <= s_axis_tdata;
            m_axis_tvalid_i <= '1';
            m_axis_tdata <= s_axis_tdata & data_i(24-1 downto 0);
            n_pk <= 0;
            m_axis_tlast_i <= s_axis_tlast;
        end case;
      end if;

    end if;
  end process;

end architecture rtl;