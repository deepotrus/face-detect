
library ieee;
use ieee.std_logic_1164.all;

entity fpga_top is
end entity fpga_top;

architecture rtl of fpga_top is

  signal M_AXIS_MM2S_0_tdata  : STD_LOGIC_VECTOR ( 31 downto 0 );
  signal M_AXIS_MM2S_0_tkeep  : STD_LOGIC_VECTOR ( 3 downto 0 );
  signal M_AXIS_MM2S_0_tlast  : STD_LOGIC;
  signal M_AXIS_MM2S_0_tready : STD_LOGIC;
  signal M_AXIS_MM2S_0_tvalid : STD_LOGIC;
  signal S_AXIS_S2MM_0_tdata  : STD_LOGIC_VECTOR ( 31 downto 0 );
  signal S_AXIS_S2MM_0_tkeep  : STD_LOGIC_VECTOR ( 3 downto 0 );
  signal S_AXIS_S2MM_0_tlast  : STD_LOGIC;
  signal S_AXIS_S2MM_0_tready : STD_LOGIC;
  signal S_AXIS_S2MM_0_tvalid : STD_LOGIC;

  signal clk : std_logic;
  signal rst : std_logic;
  signal rstn : std_logic;

begin

  rst <= not (rstn);
  i_yuyv2gray_converter : entity work.yuyv2gray
    port map(
      clk => clk, 
      rst => rst, 
      m_axis_mm2s_tdata => M_AXIS_MM2S_0_tdata,  
      m_axis_mm2s_tkeep => M_AXIS_MM2S_0_tkeep,  
      m_axis_mm2s_tlast => M_AXIS_MM2S_0_tlast,  
      m_axis_mm2s_tready => M_AXIS_MM2S_0_tready,
      m_axis_mm2s_tvalid => M_AXIS_MM2S_0_tvalid, 
      s_axis_s2mm_tdata => S_AXIS_S2MM_0_tdata,  
      s_axis_s2mm_tkeep => S_AXIS_S2MM_0_tkeep,
      s_axis_s2mm_tlast => S_AXIS_S2MM_0_tlast,
      s_axis_s2mm_tready => S_AXIS_S2MM_0_tready,
      s_axis_s2mm_tvalid => S_AXIS_S2MM_0_tvalid
    );

  kria_system : entity work.design_1_wrapper
    port map (
      pl_clk0_0 => clk,
      peripheral_aresetn_0(0) => rstn,

      M_AXIS_MM2S_0_tdata => M_AXIS_MM2S_0_tdata,
      M_AXIS_MM2S_0_tkeep => M_AXIS_MM2S_0_tkeep,
      M_AXIS_MM2S_0_tlast => M_AXIS_MM2S_0_tlast,
      M_AXIS_MM2S_0_tready => M_AXIS_MM2S_0_tready,
      M_AXIS_MM2S_0_tvalid => M_AXIS_MM2S_0_tvalid,
      S_AXIS_S2MM_0_tdata => S_AXIS_S2MM_0_tdata,
      S_AXIS_S2MM_0_tkeep => S_AXIS_S2MM_0_tkeep,
      S_AXIS_S2MM_0_tlast => S_AXIS_S2MM_0_tlast,
      S_AXIS_S2MM_0_tready => S_AXIS_S2MM_0_tready,
      S_AXIS_S2MM_0_tvalid => S_AXIS_S2MM_0_tvalid 
    );

end architecture;