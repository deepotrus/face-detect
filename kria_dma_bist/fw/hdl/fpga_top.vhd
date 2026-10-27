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

begin

  S_AXIS_S2MM_0_tdata <= M_AXIS_MM2S_0_tdata;
  S_AXIS_S2MM_0_tkeep  <= M_AXIS_MM2S_0_tkeep;
  S_AXIS_S2MM_0_tlast  <= M_AXIS_MM2S_0_tlast;
  S_AXIS_S2MM_0_tvalid <= M_AXIS_MM2S_0_tvalid;

  M_AXIS_MM2S_0_tready <= S_AXIS_S2MM_0_tready;

  kria_system : entity work.design_1_wrapper
    port map (
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