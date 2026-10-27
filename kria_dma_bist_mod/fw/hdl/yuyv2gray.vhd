library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- convert yuyv frames into gray scale by simply dropping bits.
entity yuyv2gray is
  port (
    clk : in std_logic;
    rst : in std_logic;

    m_axis_mm2s_tdata  : in std_logic_vector ( 31 downto 0 );
    m_axis_mm2s_tkeep  : in std_logic_vector ( 3 downto 0 );
    m_axis_mm2s_tlast  : in std_logic;
    m_axis_mm2s_tready : out std_logic;
    m_axis_mm2s_tvalid : in std_logic;

    s_axis_s2mm_tdata  : out std_logic_vector ( 31 downto 0 );
    s_axis_s2mm_tkeep  : out std_logic_vector ( 3 downto 0 );
    s_axis_s2mm_tlast  : out std_logic;
    s_axis_s2mm_tready : in std_logic;
    s_axis_s2mm_tvalid : out std_logic
  );
end entity yuyv2gray;

architecture rtl of yuyv2gray is
  signal hold : std_logic_vector(16-1 downto 0);
  signal odd : std_logic;

  signal s_axis_s2mm_tvalid_i : std_logic;
  signal m_axis_mm2s_tready_i : std_logic;
  signal s_axis_s2mm_tlast_i : std_logic;
begin

  -- MM2S has
  -- data[7:0] = Y0     keep
  -- data[15:8] = U     drop
  -- data[23:16] = Y1   keep
  -- data[31:24] = B    drop

  s_axis_s2mm_tvalid <= s_axis_s2mm_tvalid_i; 
  m_axis_mm2s_tready <= m_axis_mm2s_tready_i;
  s_axis_s2mm_tlast <= s_axis_s2mm_tlast_i;
  s_axis_s2mm_tkeep <= "1111";

  m_axis_mm2s_tready_i <= '1' when odd = '0'
                     else (not s_axis_s2mm_tvalid_i) or s_axis_s2mm_tready;

  p_fsm : process(clk, rst)
  begin
    if (rst='1') then
      s_axis_s2mm_tvalid_i <= '0';
      odd <= '0';
    elsif (clk'event and clk='1') then

      -- out fire handshake
      if (s_axis_s2mm_tvalid_i = '1' and s_axis_s2mm_tready = '1') then
        s_axis_s2mm_tvalid_i <= '0';
      end if;

      -- in fire handshake
      if (m_axis_mm2s_tvalid = '1' and m_axis_mm2s_tready_i = '1') then
        if (odd = '0') then
          hold <= m_axis_mm2s_tdata(24-1 downto 16) & m_axis_mm2s_tdata(8-1 downto 0);
          odd <= '1';
        else
          s_axis_s2mm_tvalid_i <= '1';
          s_axis_s2mm_tdata <= m_axis_mm2s_tdata(24-1 downto 16) & m_axis_mm2s_tdata(8-1 downto 0) & hold;
          s_axis_s2mm_tlast_i <= m_axis_mm2s_tlast;
          odd <= '0';
        end if;
      end if;

    end if;
  end process;

end architecture;