library ieee;
use ieee.std_logic_1164.all;

-- FINN integration test: MM2S --> finn_design_0 (TFC MNIST, tfc_example) --> S2MM
--
--   MM2S : one 28x28 uint8 image per DMA transfer = 196 words of 32 bit (4 pixels per word,
--          first pixel in bits 7:0). FINN counts the words itself, so MM2S tlast/tkeep are unused.
--   S2MM : 8-bit stream, one byte per image = the predicted digit. With one image per DMA
--          transfer every output beat is the last one, so tlast is always '1'.
--
-- finn_design_0 is the stitched IP from kria_face_detect/finn/tfc_example/output_tfc_kv260,
-- instantiated from the IP Catalog (IP repository: .../stitched_ip/ip) with that name.

entity fpga_top_test is
end entity fpga_top_test;

architecture rtl of fpga_top_test is

  component finn_design_0
    port (
      ap_clk          : in  std_logic;
      ap_rst_n        : in  std_logic;
      s_axis_0_tdata  : in  std_logic_vector(31 downto 0);
      s_axis_0_tvalid : in  std_logic;
      s_axis_0_tready : out std_logic;
      m_axis_0_tdata  : out std_logic_vector(7 downto 0);
      m_axis_0_tvalid : out std_logic;
      m_axis_0_tready : in  std_logic
    );
  end component;

  signal M_AXIS_MM2S_0_tdata  : std_logic_vector(31 downto 0);
  signal M_AXIS_MM2S_0_tkeep  : std_logic_vector(3 downto 0);
  signal M_AXIS_MM2S_0_tlast  : std_logic;
  signal M_AXIS_MM2S_0_tready : std_logic;
  signal M_AXIS_MM2S_0_tvalid : std_logic;
  signal S_AXIS_S2MM_0_tdata  : std_logic_vector(7 downto 0);
  signal S_AXIS_S2MM_0_tkeep  : std_logic_vector(0 downto 0);
  signal S_AXIS_S2MM_0_tlast  : std_logic;
  signal S_AXIS_S2MM_0_tready : std_logic;
  signal S_AXIS_S2MM_0_tvalid : std_logic;

  signal clk  : std_logic;
  signal rstn : std_logic;

begin

  i_finn : finn_design_0
    port map (
      ap_clk          => clk,
      ap_rst_n        => rstn,                   -- active low, like peripheral_aresetn
      s_axis_0_tdata  => M_AXIS_MM2S_0_tdata,
      s_axis_0_tvalid => M_AXIS_MM2S_0_tvalid,
      s_axis_0_tready => M_AXIS_MM2S_0_tready,
      m_axis_0_tdata  => S_AXIS_S2MM_0_tdata,
      m_axis_0_tvalid => S_AXIS_S2MM_0_tvalid,
      m_axis_0_tready => S_AXIS_S2MM_0_tready
    );

  S_AXIS_S2MM_0_tlast <= '1';                    -- one result byte per S2MM transfer
  S_AXIS_S2MM_0_tkeep <= "1";

  kria_system : entity work.design_1_wrapper
    port map (
      pl_clk0_0               => clk,
      peripheral_aresetn_0(0) => rstn,

      M_AXIS_MM2S_0_tdata  => M_AXIS_MM2S_0_tdata,
      M_AXIS_MM2S_0_tkeep  => M_AXIS_MM2S_0_tkeep,
      M_AXIS_MM2S_0_tlast  => M_AXIS_MM2S_0_tlast,
      M_AXIS_MM2S_0_tready => M_AXIS_MM2S_0_tready,
      M_AXIS_MM2S_0_tvalid => M_AXIS_MM2S_0_tvalid,
      S_AXIS_S2MM_0_tdata  => S_AXIS_S2MM_0_tdata,
      S_AXIS_S2MM_0_tkeep  => S_AXIS_S2MM_0_tkeep,
      S_AXIS_S2MM_0_tlast  => S_AXIS_S2MM_0_tlast,
      S_AXIS_S2MM_0_tready => S_AXIS_S2MM_0_tready,
      S_AXIS_S2MM_0_tvalid => S_AXIS_S2MM_0_tvalid
    );

end architecture;
